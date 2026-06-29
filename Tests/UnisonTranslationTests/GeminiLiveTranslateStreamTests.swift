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
