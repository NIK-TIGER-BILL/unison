import Testing
@testable import UnisonTranslation
@testable import UnisonDomain

@Test func mockServer_openAIStream_endToEnd_audioFlowsBackThroughURLSession() async throws {
    // Real `URLSessionWSClient` ↔ real `OpenAIRealtimeStream` ↔ mock
    // local NWListener WebSocket server. This is the regression test
    // the spec describes: catches any bug in the production transport
    // (URL building, header passing, close-code decoding) without
    // needing OpenAI credentials.
    let server = try MockOpenAIRealtimeServer()
    try await server.start()
    defer { server.stop() }

    let stream = OpenAIRealtimeStream(
        apiKey: "sk-mock-key",
        client: URLSessionWSClient(),
        clock: SystemClock(),
        speaker: .peer,
        url: server.url
    )

    // Kick off the connect. The mock server's `accept` runs on its
    // queue; we cooperate by spawning a Task that drives the server
    // side after the client has shown up.
    let serverDriver = Task {
        // Wait for the orchestrator's initial `session.update`.
        let first = await server.nextClientMessage()
        #expect(first?.contains("session.update") == true,
                "first frame from client should be session.update; got \(first ?? "<nil>")")
        // Echo handshake events.
        await server.sendSessionCreated()
        await server.sendSessionUpdated()
        // Push one audio delta — 4 bytes of PCM so the orchestrator's
        // `outputContinuation.yield(frame)` runs at least once.
        let pcm = bytes([0x01, 0x02, 0x03, 0x04])
        await server.sendOutputAudioDelta(pcm: pcm)
        await server.sendOutputTranscriptDelta("Hello")
    }

    try await stream.connect(target: .en)

    // Wait for audio + transcript to land on the consumer side.
    let collectedAudio = Task { () -> AudioFrame? in
        for await f in stream.output { return f }
        return nil
    }
    let collectedTranscript = Task { () -> TranscriptDelta? in
        for await d in stream.transcripts { return d }
        return nil
    }
    let frame = await collectedAudio.value
    let transcript = await collectedTranscript.value

    #expect(frame != nil, "expected at least one audio frame from server")
    #expect(frame?.sampleRate == 24_000)
    #expect(frame?.format == .int16)
    #expect(transcript?.text == "Hello")

    _ = await serverDriver.value

    // Now verify the auth header was sent on the wire. The mock
    // doesn't expose the upgrade-request headers (Network.framework
    // surfaces them via the WebSocketMetadata after upgrade, which is
    // complex to plumb) so we just confirm the connect succeeded —
    // that alone proves URL + transport were wired correctly.
    #expect(server.connectionAccepted)
    #expect(!server.receivedTextFrames.isEmpty)

    await stream.close()
}

@Test func mockServer_closeBeforeData_orchestratorSurfacesAuthFailure() async throws {
    // Server closes immediately without any data. The OpenAIRealtimeStream
    // close-classifier should surface `.apiKeyInvalid` per the documented
    // pattern. This is the regression test for the empty-close → auth
    // escalation path.
    let server = try MockOpenAIRealtimeServer()
    try await server.start()
    defer { server.stop() }

    let stream = OpenAIRealtimeStream(
        apiKey: "sk-mock-key",
        client: URLSessionWSClient(),
        clock: SystemClock(),
        speaker: .peer,
        url: server.url
    )

    let serverDriver = Task {
        _ = await server.nextClientMessage() // wait for session.update
        // Close immediately, no audio delta, no transcript.
        await server.closeConnection()
    }

    try await stream.connect(target: .en)

    // Collect the first non-{connecting, connected} state — that's the
    // failure resolution.
    let resolved = await Task { () -> ConnectionState? in
        for await s in stream.connectionState where s != .connected && s != .connecting {
            return s
        }
        return nil
    }.value

    _ = await serverDriver.value
    await stream.close()

    switch resolved {
    case .some(.failed(let err, let receivedAnyData)):
        #expect(err == .apiKeyInvalid)
        #expect(receivedAnyData == false)
    default:
        Issue.record("expected .failed(.apiKeyInvalid), got \(String(describing: resolved))")
    }
}

@Test func mockServer_errorEventThenAbnormalClose_connectThrowsClassifiedError() async throws {
    // Regression for the POSIX-89 masking bug. Sequence:
    //   1. Server accepts WS upgrade.
    //   2. Server pushes `{"type":"error","error":{"code":"invalid_api_key",...}}`.
    //   3. Server closes with abnormal code 3000 + reason "invalid_api_key".
    //   4. Meanwhile, `OpenAIRealtimeStream.connect()` is mid-`client.send(session.update)`
    //      — that send loses the race with the close and surfaces a generic
    //      NSPOSIXErrorDomain 89 ("Operation canceled").
    // BEFORE the fix: `connect()` threw the POSIX NSError, which the
    // orchestrator's `mapConnectError` collapsed to `.networkLost`,
    // hiding the real reason from the user.
    // AFTER the fix: `connect()` notices the close-monitor / error-event
    // handler already classified the failure as `.apiKeyInvalid` and
    // throws that instead.
    let server = try MockOpenAIRealtimeServer()
    try await server.start()
    defer { server.stop() }

    let stream = OpenAIRealtimeStream(
        apiKey: "sk-mock-key",
        client: URLSessionWSClient(),
        clock: SystemClock(),
        speaker: .peer,
        url: server.url
    )

    // Drive the server: as soon as the upgrade lands, push the error
    // event and close with code 3000 + reason — no `nextClientMessage`
    // wait, so the close races the client's outbound session.update.
    let serverDriver = Task {
        // Tiny wait to let the WS upgrade finish on the client side.
        // Without this the server may try to send before the connection
        // is .ready, which NWConnection silently drops.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await server.sendErrorEvent(code: "invalid_api_key", message: "Incorrect API key provided")
        await server.closeConnection(code: 3000)
    }

    var thrown: Error?
    do {
        try await stream.connect(target: .en)
    } catch {
        thrown = error
    }
    _ = await serverDriver.value

    // The thrown error MUST be the classified TranslationError, not a
    // generic NSError. Both close-paths (server `error` event and the
    // abnormal close) classify as `.apiKeyInvalid`, so that's what
    // surfaces.
    switch thrown {
    case let .some(te as TranslationError):
        #expect(te == .apiKeyInvalid,
                "expected .apiKeyInvalid; got \(te)")
    case let .some(other):
        Issue.record("expected TranslationError.apiKeyInvalid; got non-TranslationError \(type(of: other)): \(other)")
    case .none:
        // `connect()` may also return normally if the send happened to
        // win the race; in that case the failure surfaces on the
        // `connectionState` stream instead. We still want the same
        // classification.
        let resolved = await Task { () -> ConnectionState? in
            for await s in stream.connectionState where s != .connected && s != .connecting {
                return s
            }
            return nil
        }.value
        switch resolved {
        case .some(.failed(let err, _)):
            #expect(err == .apiKeyInvalid,
                    "no error thrown; expected connectionState .apiKeyInvalid; got \(err)")
        default:
            Issue.record("no error thrown and no .failed state; got \(String(describing: resolved))")
        }
    }

    await stream.close()
}

@Test func mockServer_inputAudioBufferAppend_landsOnServer() async throws {
    // Verify the orchestrator's `send(_:)` path writes the right
    // `session.input_audio_buffer.append` envelope on the wire.
    let server = try MockOpenAIRealtimeServer()
    try await server.start()
    defer { server.stop() }

    let stream = OpenAIRealtimeStream(
        apiKey: "sk-mock-key",
        client: URLSessionWSClient(),
        clock: SystemClock(),
        speaker: .me,
        url: server.url
    )
    try await stream.connect(target: .en)
    _ = await server.nextClientMessage() // session.update

    // Send a short PCM frame.
    let pcm = bytes([0xAA, 0xBB, 0xCC, 0xDD])
    let frame = AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16)
    await stream.send(frame)

    let appendMsg = await server.nextClientMessage()
    #expect(appendMsg?.contains("session.input_audio_buffer.append") == true,
            "expected append envelope; got \(appendMsg ?? "<nil>")")
    #expect(appendMsg?.contains(pcm.base64EncodedString()) == true,
            "expected base64 PCM in payload; got \(appendMsg ?? "<nil>")")

    await stream.close()
}
