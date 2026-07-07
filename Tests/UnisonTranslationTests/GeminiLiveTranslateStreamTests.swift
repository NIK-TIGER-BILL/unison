import Foundation
import Testing
@testable import UnisonTranslation
import UnisonDomain

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

    @Test func transcriptsCarryLanguageTag() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .ru)
        var it = stream.transcripts.makeAsyncIterator()

        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"hello","languageCode":"en"}}}"#))
        let original = await it.next()
        #expect(original?.kind == .original)
        #expect(original?.text == "hello")
        #expect(original?.language == .en)

        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"привет","languageCode":"ru"}}}"#))
        let translated = await it.next()
        #expect(translated?.kind == .translated)
        #expect(translated?.text == "привет")
        #expect(translated?.language == .ru)
    }

    // An utterance's original AND its lagging translation share ONE entryId, so
    // `TranscriptStore` groups them into a single history entry; the id rotates
    // after a speech pause (input gap ≥ 1.5 s) so the next utterance is a fresh
    // entry. Regression: emitting a fresh UUID per delta fragmented Gemini
    // meeting history/export into one-entry-per-chunk.
    @Test func transcripts_shareEntryIdWithinUtterance_rotateOnPause() async throws {
        let ws = FakeWSClient()
        let clock = ManualClock(Date(timeIntervalSince1970: 1000))
        let stream = GeminiLiveTranslateStream(apiKey: "AQ.k", client: ws, clock: clock, speaker: .peer)
        try await stream.connect(target: .ru)
        var it = stream.transcripts.makeAsyncIterator()

        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"Hello","languageCode":"en"}}}"#))
        let original = await it.next()
        clock.advance(0.4)   // translation lag < utteranceGap → same utterance
        ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"Привет","languageCode":"ru"}}}"#))
        let translation = await it.next()
        clock.advance(2.0)   // speech pause ≥ utteranceGap → new utterance
        ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"World","languageCode":"en"}}}"#))
        let nextOriginal = await it.next()

        #expect(original?.entryId == translation?.entryId)   // paired within the utterance
        #expect(nextOriginal?.entryId != original?.entryId)  // rotated after the pause
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

// Регрессия D3: goAway — сервер предупреждает о скором закрытии сессии
// (лимит Live API). Стрим обязан немедленно сдать себя оркестратору под
// проактивный реконнект, а не молча дожидаться обрыва сокета.
extension GeminiLiveTranslateStreamTests {
    @Test func goAway_yieldsServerGoingAwayFailure() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .en)
        // Данные уже шли — receivedAnyData должен уехать в событие как true.
        ws.push(.text(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}"#))
        ws.push(.text(#"{"goAway":{"timeLeft":"10s"}}"#))

        var it = stream.connectionState.makeAsyncIterator()
        var failed: ConnectionState?
        // connecting → connected → failed(.serverGoingAway)
        for _ in 0..<5 {
            guard let s = await it.next() else { break }
            if case .failed = s { failed = s; break }
        }
        guard case .failed(let err, let receivedAnyData) = failed else {
            Issue.record("не дождались .failed, got \(String(describing: failed))")
            return
        }
        #expect(err == .serverGoingAway)
        #expect(receivedAnyData == true)
    }
}
