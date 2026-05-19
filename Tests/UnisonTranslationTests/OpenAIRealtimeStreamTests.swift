import Testing
@testable import UnisonTranslation
@testable import UnisonDomain

@Test func stream_connectSendsSessionUpdateWithTargetLanguage() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    #expect(ws.connectCalls.count == 1)
    #expect(ws.connectCalls[0].1["Authorization"] == "Bearer sk-test")

    if case .text(let json) = ws.sentMessages.first {
        #expect(json.contains("session.update"))
        #expect(json.contains("\"language\":\"en\""))
    } else {
        Issue.record("Expected session.update text message")
    }
}

@Test func stream_sendEncodesPCMAsBase64Append() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)
    ws.sentMessages.removeAll()

    let pcm = bytes([0x10, 0x20, 0x30, 0x40])
    let frame = AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16)
    await stream.send(frame)

    if case .text(let json) = ws.sentMessages.first {
        #expect(json.contains("input_audio_buffer.append"))
        #expect(json.contains(pcm.base64EncodedString()))
    } else {
        Issue.record("Expected append text message")
    }
}

@Test func stream_outputAudioDeltaEmitsAudioFrame() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    let collector = Task {
        var collected: [AudioFrame] = []
        for await f in stream.output { collected.append(f); break }
        return collected
    }

    let pcm = bytes([0xAA, 0xBB, 0xCC, 0xDD])
    let json = #"{"type":"output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#
    ws.push(.text(json))

    let collected = await collector.value
    #expect(collected.count == 1)
    #expect(collected[0].pcm == pcm)
    #expect(collected[0].sampleRate == 24_000)
    #expect(collected[0].format == .int16)
}

@Test func stream_outputTranscriptDeltaEmitsTranscript() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    let collector = Task { () -> TranscriptDelta? in
        for await d in stream.transcripts { return d }
        return nil
    }

    let json = #"{"type":"output_transcript.delta","delta":"Hello"}"#
    ws.push(.text(json))

    let delta = await collector.value
    #expect(delta?.text == "Hello")
    #expect(delta?.kind == .translated)
}

@Test func stream_errorEventEmitsFailedConnectionState() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    let collector = Task { () -> ConnectionState? in
        for await s in stream.connectionState where s != .connected && s != .connecting {
            return s
        }
        return nil
    }

    let json = #"{"type":"error","error":{"code":"invalid_api_key","message":"Invalid"}}"#
    ws.push(.text(json))

    let state = await collector.value
    if case .failed(let e) = state {
        #expect(e == .apiKeyInvalid)
    } else {
        Issue.record("Expected .failed(.apiKeyInvalid), got \(String(describing: state))")
    }
}

@Test func stream_closeSendsSessionCloseAndShutsDown() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    await stream.close()
    let hasClose = ws.sentMessages.contains { msg in
        if case .text(let s) = msg, s.contains("session.close") { return true } else { return false }
    }
    #expect(hasClose)
    #expect(ws.closeCalls == 1)
}
