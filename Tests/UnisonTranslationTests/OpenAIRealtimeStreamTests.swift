import Testing
@testable import UnisonTranslation
@testable import UnisonDomain

@Test func stream_connectSendsSessionUpdateWithTargetLanguage() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    #expect(ws.connectCalls.count == 1)
    // GA: Bearer-only. The `OpenAI-Beta` header is gone — the GA endpoint
    // rejects the Beta shape entirely.
    #expect(ws.connectCalls[0].1["Authorization"] == "Bearer sk-test")
    #expect(ws.connectCalls[0].1["OpenAI-Beta"] == nil)
    // URL must hit the GA endpoint with the translate model in the query.
    #expect(ws.connectCalls[0].0.absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-translate")

    if case .text(let json) = ws.sentMessages.first {
        #expect(json.contains("session.update"))
        #expect(json.contains("\"language\":\"en\""))
        // GA-only fields — proves we're not sending the legacy
        // `{"session":{"audio":{"output":{"language":"en"}}}}` shape.
        #expect(json.contains("\"transcription\""))
        #expect(json.contains("\"gpt-realtime-whisper\""))
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
    // GA event name: `session.output_audio.delta`.
    let json = #"{"type":"session.output_audio.delta","delta":"\#(pcm.base64EncodedString())"}"#
    ws.push(.text(json))

    let collected = await collector.value
    #expect(collected.count == 1)
    #expect(collected[0].pcm == pcm)
    #expect(collected[0].sampleRate == 24_000)
    #expect(collected[0].format == .int16)
}

@Test func stream_outputTranscriptDeltaEmitsTranscript() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock(), speaker: .me)
    try await stream.connect(target: .en)

    let collector = Task { () -> TranscriptDelta? in
        for await d in stream.transcripts { return d }
        return nil
    }

    // GA event name: `session.output_transcript.delta`.
    let json = #"{"type":"session.output_transcript.delta","delta":"Hello"}"#
    ws.push(.text(json))

    let delta = await collector.value
    #expect(delta?.text == "Hello")
    #expect(delta?.kind == .translated)
    #expect(delta?.speaker == .me)
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
    if case .failed(let e, _) = state {
        #expect(e == .apiKeyInvalid)
    } else {
        Issue.record("Expected .failed(.apiKeyInvalid), got \(String(describing: state))")
    }
}

@Test func stream_sessionLifecycleEvents_doNotFlipReceivedAnyData() async throws {
    // GA lifecycle events (session.created, session.updated, etc.) arrive
    // BEFORE any translation chunk. They MUST NOT set `receivedAnyData` —
    // otherwise the orchestrator's auth-failure escalation can't trip on
    // a pre-data close. This test pushes a `session.created` then closes
    // the WS normally; the resulting state must be `.failed(.apiKeyInvalid,
    // receivedAnyData: false)`.
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    let collector = Task { () -> ConnectionState? in
        for await s in stream.connectionState where s != .connected && s != .connecting {
            return s
        }
        return nil
    }

    // Server says hi (GA handshake) — should be ignored by the data tracker.
    let created = #"{"type":"session.created","event_id":"evt_1","session":{"id":"sess_1","model":"gpt-realtime-translate"}}"#
    ws.push(.text(created))
    let updated = #"{"type":"session.updated","event_id":"evt_2","session":{}}"#
    ws.push(.text(updated))

    // Then close cleanly without ever sending a translation chunk.
    ws.pushClose(.normal)

    let state = await collector.value
    if case .failed(let e, let receivedAnyData) = state {
        #expect(e == .apiKeyInvalid)
        #expect(receivedAnyData == false, "Lifecycle events must not flip receivedAnyData")
    } else {
        Issue.record("Expected .failed(.apiKeyInvalid, receivedAnyData: false), got \(String(describing: state))")
    }
}

@Test func stream_wsCloseAbnormal_emitsFailedState() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    let collector = Task { () -> ConnectionState? in
        for await s in stream.connectionState where s != .connected && s != .connecting {
            return s
        }
        return nil
    }

    ws.pushClose(.abnormal(code: 1006, reason: nil))
    let state = await collector.value
    if case .failed(let e, _) = state {
        #expect(e == .networkLost)
    } else {
        Issue.record("Expected .failed(.networkLost), got \(String(describing: state))")
    }
}

// MARK: - Close-code classifier

@Test func classifyClose_policyViolation1008_isAuthFailure() {
    let err = OpenAIRealtimeStream.classifyClose(code: 1008, reason: nil, receivedData: false)
    #expect(err == .apiKeyInvalid)
}

@Test func classifyClose_rateLimit1013() {
    let err = OpenAIRealtimeStream.classifyClose(code: 1013, reason: nil, receivedData: false)
    if case .rateLimited = err {} else {
        Issue.record("Expected .rateLimited, got \(err)")
    }
}

@Test func classifyClose_appRange4001NoData_isAuth() {
    let err = OpenAIRealtimeStream.classifyClose(code: 4001, reason: nil, receivedData: false)
    #expect(err == .apiKeyInvalid)
}

@Test func classifyClose_appRange4001WithData_isNetwork() {
    let err = OpenAIRealtimeStream.classifyClose(code: 4001, reason: nil, receivedData: true)
    #expect(err == .networkLost)
}

@Test func classifyClose_reasonInvalidAPIKey() {
    let err = OpenAIRealtimeStream.classifyClose(
        code: 1011,
        reason: #"{"error":{"code":"invalid_api_key","message":"Incorrect API key provided"}}"#,
        receivedData: false
    )
    #expect(err == .apiKeyInvalid)
}

@Test func classifyClose_reasonInsufficientQuota() {
    let err = OpenAIRealtimeStream.classifyClose(
        code: 1011,
        reason: #"{"error":{"code":"insufficient_quota"}}"#,
        receivedData: false
    )
    #expect(err == .insufficientCredits)
}

@Test func classifyClose_reasonRateLimit() {
    let err = OpenAIRealtimeStream.classifyClose(
        code: 1011,
        reason: "Too Many Requests — rate_limit_exceeded",
        receivedData: false
    )
    if case .rateLimited = err {} else {
        Issue.record("Expected .rateLimited, got \(err)")
    }
}

@Test func classifyClose_protocolError1002_isNetwork() {
    let err = OpenAIRealtimeStream.classifyClose(code: 1002, reason: nil, receivedData: false)
    #expect(err == .networkLost)
}

@Test func classifyClose_reasonBetaApiShapeDisabled_isAuthFailure() {
    // GA-migration sentinel: if anyone re-introduces the Beta endpoint or
    // header, the server now responds with this shape. Surface it as
    // `.apiKeyInvalid` so the UI shows the credentials-error row instead
    // of a perpetual reconnect loop.
    let err = OpenAIRealtimeStream.classifyClose(
        code: 1008,
        reason: #"{"error":{"type":"invalid_request_error","code":"beta_api_shape_disabled","message":"The Realtime Beta API is no longer supported."}}"#,
        receivedData: false
    )
    #expect(err == .apiKeyInvalid)
}

@Test func stream_normalCloseBeforeData_treatedAsAuthFailure() async throws {
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    let collector = Task { () -> ConnectionState? in
        for await s in stream.connectionState where s != .connected && s != .connecting {
            return s
        }
        return nil
    }

    // Server accepted the handshake then closed cleanly before sending
    // a single byte of translation. This is OpenAI's auth-rejection
    // signature — treat as `.apiKeyInvalid`, not `.networkLost`.
    ws.pushClose(.normal)
    let state = await collector.value
    if case .failed(let e, let receivedAnyData) = state {
        #expect(e == .apiKeyInvalid)
        #expect(receivedAnyData == false, "Auth-fail close happens before any data — receivedAnyData must be false so the orchestrator can escalate to terminal")
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
