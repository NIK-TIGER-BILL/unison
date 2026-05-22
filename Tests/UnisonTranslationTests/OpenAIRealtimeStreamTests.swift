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
    // URL must hit the GA *translations* endpoint with the translate
    // model in the query — `/v1/realtime/translations` sets the
    // session.type to "translation" server-side, the canonical shape.
    #expect(ws.connectCalls[0].0.absoluteString == "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")
    // OpenAI-Safety-Identifier (hashed bundle ID + host UUID — no PII)
    // is recommended per docs to reduce abuse risk. In CI / SPM tests
    // the IORegistry may be unavailable, in which case we skip the
    // header rather than fabricate one — both cases are valid.
    if let id = ws.connectCalls[0].1["OpenAI-Safety-Identifier"] {
        #expect(id.count == 64) // SHA-256 hex digest
        #expect(id.allSatisfy { $0.isHexDigit })
    }

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
        // GA event name carries `session.` prefix per cookbook.
        #expect(json.contains("session.input_audio_buffer.append"))
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

@Test func stream_connectSendThrowsPOSIX_butCloseAlreadyClassified_propagatesClassifiedError() async throws {
    // Regression for the POSIX-89 masking bug. Production sequence:
    //   1. WS handshake succeeds.
    //   2. Server pushes a close with code 3000 + reason "invalid_api_key"
    //      (or fires a server `error` event with code `invalid_api_key`).
    //   3. Client-side, `OpenAIRealtimeStream.connect()` is mid-
    //      `client.send(session.update)`. URLSession marshals the send
    //      *after* the close has been processed, surfaces a generic
    //      `NSPOSIXErrorDomain code=89 "Operation canceled"` NSError.
    //
    // Before the fix, `connect()` threw the POSIX NSError, which the
    // orchestrator's `mapConnectError` collapsed to `.networkLost` —
    // hiding the real reason. The fix introduces a sticky
    // `lastClassifiedError` so the send catch-block substitutes the
    // classified `TranslationError` for the transport-level noise.
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())

    ws.nextSendShouldThrow = posixOperationCanceledError()
    // Race-emulation hook: simulate the close arriving *immediately
    // before* the send returns its error. This is what the production
    // transport produces — the close-monitor task processes the close
    // first, the send throws second.
    ws.beforeSendThrow = { [weak ws] in
        ws?.pushClose(.abnormal(
            code: 3000,
            reason: #"{"error":{"code":"invalid_api_key","message":"Incorrect API key provided"}}"#
        ))
    }

    var thrown: Error?
    do {
        try await stream.connect(target: .en)
    } catch {
        thrown = error
    }

    // The thrown error MUST be `.apiKeyInvalid`, not the POSIX NSError.
    guard let te = thrown as? TranslationError else {
        Issue.record("expected TranslationError.apiKeyInvalid; got \(String(describing: thrown))")
        return
    }
    #expect(te == .apiKeyInvalid, "expected .apiKeyInvalid; got \(te)")
}

@Test func stream_connectSendThrowsPOSIX_withoutPriorClassification_propagatesPOSIX() async throws {
    // Counter-test for the sticky-classification fix: if the send
    // genuinely fails for a non-classified reason (network down, DNS,
    // anything that isn't preceded by a WS close or server error event),
    // we should NOT manufacture a `TranslationError` — the orchestrator
    // is allowed to fall back to `.networkLost` via `mapConnectError`.
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())

    ws.nextSendShouldThrow = GenericSendError()
    // No beforeSendThrow hook — nothing classifies before the throw.

    var thrown: Error?
    do {
        try await stream.connect(target: .en)
    } catch {
        thrown = error
    }
    #expect(thrown is GenericSendError,
            "with no prior classification, the original send error must propagate; got \(String(describing: thrown))")
}

@Test func stream_connectSendThrowsPOSIX_serverErrorEventClassifies_propagatesClassifiedError() async throws {
    // Variant: classification comes from the server `error` event path
    // (not the WS close), then the send fails. The fix must also catch
    // this — server error events are the most common production signal
    // for credential rejection.
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())

    ws.nextSendShouldThrow = posixOperationCanceledError()
    ws.beforeSendThrow = { [weak ws] in
        ws?.push(.text(#"{"type":"error","error":{"code":"invalid_api_key","message":"bad"}}"#))
    }

    var thrown: Error?
    do {
        try await stream.connect(target: .en)
    } catch {
        thrown = error
    }
    guard let te = thrown as? TranslationError else {
        Issue.record("expected TranslationError.apiKeyInvalid; got \(String(describing: thrown))")
        return
    }
    #expect(te == .apiKeyInvalid, "expected .apiKeyInvalid; got \(te)")
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

@Test func stream_close_waitsForSessionClosedBeforeShuttingDown() async throws {
    // Per OpenAI cookbook: "send `session.close`, then continue reading
    // events until `session.closed` confirmation — system flushes pending
    // audio." Our `close()` parks on a grace continuation that wakes when
    // a `session.closed` event arrives. Push one in flight to confirm the
    // graceful path resolves promptly instead of riding the 500ms timeout.
    let ws = FakeWSClient()
    let stream = OpenAIRealtimeStream(apiKey: "sk-test", client: ws, clock: SystemClock())
    try await stream.connect(target: .en)

    // Push `session.closed` *before* calling close — the receive task will
    // process it ahead of close()'s grace wait and resolve the waiter
    // immediately.
    ws.push(.text(#"{"type":"session.closed"}"#))
    // Give the receive task a moment to consume the event.
    try? await Task.sleep(nanoseconds: 50_000_000)

    // Wall-clock the close() call using stdlib `ContinuousClock` —
    // avoids importing Foundation/Date here so we don't trigger the
    // missing `_Testing_Foundation` cross-import overlay on Command
    // Line Tools setups (same trick `Helpers.swift` uses).
    let clock = ContinuousClock()
    let start = clock.now
    await stream.close()
    let elapsed = start.duration(to: clock.now)
    // Should finish well before the 500ms grace timeout when the server
    // confirms closure ahead of time. `Duration` only exposes
    // `components.seconds + attoseconds`; cast to Double via the seconds
    // component since 400ms ≪ 1s never overflows.
    let elapsedSec = Double(elapsed.components.seconds) +
        Double(elapsed.components.attoseconds) / 1e18
    #expect(elapsedSec < 0.4, "close() should resolve quickly when session.closed already arrived (took \(elapsedSec)s)")
}
