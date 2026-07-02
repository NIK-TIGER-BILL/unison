import Foundation
import Testing
@testable import UnisonTranslation
import UnisonDomain

/// Minimal controllable clock for the utterance-gap logic: `now()` returns
/// a virtual instant advanced explicitly by the test. (`sleep` is unused by
/// the stream's transcript path.)
private final class SteppingClock: UnisonDomain.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000_000)
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func sleep(for seconds: TimeInterval) async throws {}
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@Suite struct GeminiLiveTranslateStreamTests {
    @Test func connectSendsSetupWithKeyInQueryAndTarget() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.test-key", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .ru)

        let (url, headers) = ws.connectCalls[0]
        #expect(url.absoluteString.contains("key=AQ.test-key"))
        #expect(headers["Authorization"] == nil)

        let setup = ws.sentMessages.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.first
        #expect(setup?.contains("gemini-3.5-live-translate-preview") == true)
        #expect(setup?.contains("\"targetLanguageCode\":\"ru\"") == true)
    }

    @Test func inputWireSampleRateIs16k() {
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: FakeWSClient(), clock: SystemClock(), speaker: .me)
        #expect(stream.inputWireSampleRate == 16_000)
    }

    @Test func sendEncodesRealtimeAudio() async {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .me)
        await stream.send(AudioFrame(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000, channels: 1, format: .int16))
        let msg = ws.sentMessages.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.last
        #expect(msg?.contains("realtimeInput") == true)
        #expect(msg?.contains("audio/pcm;rate=16000") == true)
    }

    @Test func audioDeltaYieldsFrameAt24k() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .en)
        ws.push(.text(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}"#))

        var iterator = stream.output.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.sampleRate == 24_000)
        #expect(frame?.format == .int16)
    }

    @Test func preDataNormalCloseClassifiesAsApiKeyInvalid() {
        let mapped = GeminiLiveTranslateStream.classifyClose(code: 1008, reason: nil, receivedData: false)
        #expect(mapped == .apiKeyInvalid)
    }

    @Test func transcriptsMapToOriginalAndTranslated() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .en)
        var it = stream.transcripts.makeAsyncIterator()

        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"привет"}}}"#))
        let d1 = await it.next()
        #expect(d1?.kind == .original)
        #expect(d1?.text == "привет")

        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"hi"}}}"#))
        let d2 = await it.next()
        #expect(d2?.kind == .translated)
        #expect(d2?.text == "hi")
    }

    @Test func turnCompleteRotatesEntryId() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .en)
        var it = stream.transcripts.makeAsyncIterator()

        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"a"}}}"#))
        let first = await it.next()
        ws.push(.text(#"{"serverContent":{"turnComplete":true}}"#))
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"b"}}}"#))
        let second = await it.next()
        #expect(first?.entryId != second?.entryId)
    }

    // MARK: - Original ↔ translation pairing (the off-by-one bubble bug)

    /// Field screenshot (2026-07-02): every bubble held the TRANSLATION of
    /// utterance N together with the ORIGINAL of utterance N+1. Cause: the
    /// translation lags the original, so the next utterance's input
    /// transcription lands BEFORE the previous turn's `turnComplete` — and a
    /// single shared entryId glued it into the previous bubble. The fix
    /// segments the INPUT side on speech pauses (≥0.6 s gap = a VAD turn
    /// boundary by construction, VAD closes at ~0.3 s) once the current
    /// turn's output has started, and routes OUTPUT deltas through a FIFO of
    /// pending utterance entries popped at `turnComplete`.
    @Test func lateTranslation_pairsWithItsOwnUtterance_notTheNext() async throws {
        let ws = FakeWSClient()
        let clock = SteppingClock()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: clock, speaker: .peer)
        try await stream.connect(target: .ru)
        var it = stream.transcripts.makeAsyncIterator()

        // Utterance 1: original, then its translation starts streaming.
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"this could be several calls"}}}"#))
        let in1 = await it.next()
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"Это может быть несколько вызовов."}}}"#))
        let out1 = await it.next()

        // Speaker resumes after a real speech pause (≥0.6 s ⇒ the VAD closed
        // turn 1) — but the model hasn't sent turnComplete yet.
        clock.advance(by: 0.8)
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"for instance agentic tools"}}}"#))
        let in2 = await it.next()

        // Turn 1 closes; utterance 2's translation arrives afterwards.
        ws.push(.text(#"{"serverContent":{"turnComplete":true}}"#))
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"Например, агентные инструменты"}}}"#))
        let out2 = await it.next()

        #expect(in1?.entryId == out1?.entryId, "utterance 1: original and translation share a bubble")
        #expect(in2?.entryId != in1?.entryId, "utterance 2's original must open its own bubble, not glue into bubble 1")
        #expect(out2?.entryId == in2?.entryId, "utterance 2's translation must land in utterance 2's bubble")
    }

    /// Regression guard: within ONE long turn the model interleaves input
    /// and output with short delivery pauses — that must stay a single
    /// bubble (sub-0.6 s gaps are not VAD boundaries).
    @Test func streamingInterleave_shortPauses_stayOneBubble() async throws {
        let ws = FakeWSClient()
        let clock = SteppingClock()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: clock, speaker: .peer)
        try await stream.connect(target: .ru)
        var it = stream.transcripts.makeAsyncIterator()

        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"hello"}}}"#))
        let a = await it.next()
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"привет"}}}"#))
        let b = await it.next()
        clock.advance(by: 0.3)
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":" world"}}}"#))
        let c = await it.next()
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":" мир"}}}"#))
        let d = await it.next()

        #expect(a?.entryId == b?.entryId)
        #expect(a?.entryId == c?.entryId, "0.3 s pause inside one turn must not split the bubble")
        #expect(a?.entryId == d?.entryId)
    }

    /// Two utterances queued ahead of their translations: outputs must
    /// follow turn order through BOTH turnCompletes (FIFO, not latest-entry).
    @Test func twoQueuedUtterances_translationsFollowTurnOrder() async throws {
        let ws = FakeWSClient()
        let clock = SteppingClock()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: clock, speaker: .peer)
        try await stream.connect(target: .ru)
        var it = stream.transcripts.makeAsyncIterator()

        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"one"}}}"#))
        let in1 = await it.next()
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"раз"}}}"#))
        _ = await it.next()
        clock.advance(by: 1.0)
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"two"}}}"#))
        let in2 = await it.next()
        // Turn 1 closes → utterance 2's translation, then speaker starts 3.
        ws.push(.text(#"{"serverContent":{"turnComplete":true}}"#))
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"два"}}}"#))
        let out2 = await it.next()
        clock.advance(by: 1.0)
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"three"}}}"#))
        let in3 = await it.next()
        ws.push(.text(#"{"serverContent":{"turnComplete":true}}"#))
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"три"}}}"#))
        let out3 = await it.next()

        #expect(in2?.entryId != in1?.entryId)
        #expect(out2?.entryId == in2?.entryId, "turn-2 translation → utterance-2 bubble")
        #expect(in3?.entryId != in2?.entryId)
        #expect(out3?.entryId == in3?.entryId, "turn-3 translation → utterance-3 bubble")
    }

    @Test func decodesAudioFromBinaryFrame() async throws {
        // Gemini delivers serverContent as BINARY WebSocket frames (not text
        // like OpenAI); handle(_:) must decode `.data` frames too, else the
        // whole output stream is silently dropped.
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .en)
        let json = #"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}"#
        ws.push(.data(Data(json.utf8)))
        var iterator = stream.output.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.sampleRate == 24_000)
        #expect(frame?.format == .int16)
    }
}
