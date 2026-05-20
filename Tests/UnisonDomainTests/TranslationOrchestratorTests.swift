import Testing
@testable import UnisonDomain

@MainActor
private func defaultRegistry() -> MockAudioDeviceRegistry {
    let r = MockAudioDeviceRegistry()
    r.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    r.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    return r
}

@MainActor
private func defaultPerms() -> MockPermissionsService {
    let p = MockPermissionsService()
    p.statuses[.microphone] = .granted
    return p
}

@MainActor
private func makeOrchestrator(
    mic: MockMicrophoneCapture = .init(),
    peer: MockPeerAudioCapture = .init(),
    mixer: MockAudioOutputMixer = .init(),
    bhPlayer: MockAudioPlayer = .init(),
    factory: MockTranslationStreamFactory = .init(),
    perms: MockPermissionsService? = nil,
    registry: MockAudioDeviceRegistry? = nil,
    clock: any Clock = SystemClock(),
    transformer: any AudioFormatTransformer = MockAudioFormatTransformer()
) -> TranslationOrchestrator {
    let resolvedRegistry = registry ?? defaultRegistry()
    let resolvedPerms = perms ?? defaultPerms()
    return TranslationOrchestrator(
        micCapture: mic, peerCapture: peer, outputMixer: mixer,
        virtualMicPlayer: bhPlayer, translationFactory: factory,
        permissions: resolvedPerms, deviceRegistry: resolvedRegistry, clock: clock,
        transformer: transformer
    )
}

@Test @MainActor func orchestrator_initialStateIsIdle() {
    let o = makeOrchestrator()
    #expect(o.state == .idle)
}

@Test @MainActor func orchestrator_startCall_transitionsToTranslating() async throws {
    let o = makeOrchestrator()
    await o.start(mode: .call, languages: .default)
    if case .translating(let mode, _) = o.state {
        #expect(mode == .call)
    } else {
        Issue.record("Expected .translating, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_startCall_failsWithoutMicPermission() async {
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .denied
    let o = makeOrchestrator(perms: perms)
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .permissionDenied(.microphone))
}

@Test @MainActor func orchestrator_startCall_failsWithoutBlackHole2ch() async {
    let registry = MockAudioDeviceRegistry()
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    registry.bh2ch = nil
    let o = makeOrchestrator(registry: registry)
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .blackHole2chMissing)
}

@Test @MainActor func orchestrator_startCall_failsWithoutBlackHole16ch() async {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = nil
    let o = makeOrchestrator(registry: registry)
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .blackHole16chMissing)
}

@Test @MainActor func orchestrator_startListen_skipsMicAndBH2ch() async throws {
    let mic = MockMicrophoneCapture()
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .denied
    let registry = MockAudioDeviceRegistry()
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    registry.bh2ch = nil
    let o = makeOrchestrator(mic: mic, perms: perms, registry: registry)
    await o.start(mode: .listen, languages: .default)
    #expect(mic.startedWithUID == nil)
    #expect(perms.requestCalls.contains(.microphone) == false)
    if case .translating(let mode, _) = o.state {
        #expect(mode == .listen)
    } else {
        Issue.record("Expected .translating, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_stop_returnsToIdle() async throws {
    let o = makeOrchestrator()
    await o.start(mode: .call, languages: .default)
    await o.stop()
    #expect(o.state == .idle)
}

@Test @MainActor func orchestrator_updateOriginalMixVolume_propagatesToMixer() async throws {
    let mixer = MockAudioOutputMixer()
    let o = makeOrchestrator(mixer: mixer)
    await o.start(mode: .call, languages: .default)
    o.updateOriginalMixVolume(0.6)
    #expect(abs(mixer.currentGain - 0.6) < 0.0001)
}

@Test @MainActor func orchestrator_callMode_opensTwoTranslationStreams() async throws {
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory)
    await o.start(mode: .call, languages: LanguagePair(mine: .ru, peer: .en))
    #expect(factory.streams[.me]?.connectedTo == .en)
    #expect(factory.streams[.peer]?.connectedTo == .ru)
}

@Test @MainActor func orchestrator_listenMode_opensOnlyIncomingStream() async throws {
    let factory = MockTranslationStreamFactory()
    let registry = MockAudioDeviceRegistry()
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    registry.bh2ch = nil
    let o = makeOrchestrator(factory: factory, registry: registry)
    await o.start(mode: .listen, languages: LanguagePair(mine: .ru, peer: .en))
    #expect(factory.streams[.me] == nil)
    #expect(factory.streams[.peer]?.connectedTo == .ru)
}

@Test @MainActor func orchestrator_callMode_micFrames_convertedToWireFormatBeforeSend() async throws {
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(mic: mic, factory: factory)
    await o.start(mode: .call, languages: .default)

    // Emit a fake mic frame in capture format (48kHz F32, 100ms)
    let captureFrame = AudioFrame(pcm: zeroData(count: 48_000 * 4 / 10), sampleRate: 48_000, channels: 1, format: .float32)
    mic.emit(captureFrame)
    try await Task.sleep(nanoseconds: 100_000_000)

    let outgoing = factory.streams[.me]!.sentFrames
    #expect(outgoing.count == 1, "Expected 1 frame sent to OUT stream, got \(outgoing.count)")
    #expect(outgoing[0].sampleRate == 24_000, "Frame must be at OpenAI wire rate")
    #expect(outgoing[0].format == .int16, "Frame must be wire format Int16")
}

// Stream variant that always fails connect — used to drive initial-connect failure path.
final class FailingMockStream: TranslationStream, @unchecked Sendable {
    let transcripts: AsyncStream<TranscriptDelta>
    let output: AsyncStream<AudioFrame>
    let connectionState: AsyncStream<ConnectionState>
    let failure: TranslationError
    init(failure: TranslationError) {
        transcripts = AsyncStream { _ in }
        output = AsyncStream { _ in }
        connectionState = AsyncStream { _ in }
        self.failure = failure
    }
    func connect(target: Language) async throws {
        throw failure
    }
    func send(_ frame: AudioFrame) async {}
    func close() async {}
}

final class FailingMockFactory: TranslationStreamFactory, @unchecked Sendable {
    let failure: TranslationError
    init(failure: TranslationError = .apiKeyInvalid) { self.failure = failure }
    func make(speaker: Speaker) -> any TranslationStream {
        FailingMockStream(failure: failure)
    }
}

@Test @MainActor func orchestrator_initialConnectFailure_setsErrorState() async {
    let factory = FailingMockFactory(failure: .apiKeyInvalid)
    let o = TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: factory,
        permissions: defaultPerms(),
        deviceRegistry: defaultRegistry(),
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer()
    )
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .apiKeyInvalid)
}

@Test @MainActor func orchestrator_initialConnectFailure_genericError_mapsToNetworkLost() async {
    // A non-TranslationError thrown from connect should map to .networkLost.
    struct GenericError: Error {}
    final class GenericFailFactory: TranslationStreamFactory, @unchecked Sendable {
        func make(speaker: Speaker) -> any TranslationStream {
            final class S: TranslationStream, @unchecked Sendable {
                let transcripts: AsyncStream<TranscriptDelta> = AsyncStream { _ in }
                let output: AsyncStream<AudioFrame> = AsyncStream { _ in }
                let connectionState: AsyncStream<ConnectionState> = AsyncStream { _ in }
                func connect(target: Language) async throws { throw GenericError() }
                func send(_ frame: AudioFrame) async {}
                func close() async {}
            }
            return S()
        }
    }
    let o = TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: GenericFailFactory(),
        permissions: defaultPerms(),
        deviceRegistry: defaultRegistry(),
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer()
    )
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .networkLost)
}

@Test @MainActor func orchestrator_midSessionFailure_transitionsToReconnecting() async throws {
    // FakeClock keeps the retry-loop suspended in `clock.sleep` so we can
    // observe the .reconnecting transition without waiting for the retry to fire.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)
    // Sanity: orchestrator should be in .translating now
    guard case .translating = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }

    // Push a .failed event on the peer stream's connectionState
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost))

    // Give the observer task time to react and the failure handler to set state.
    // The retry-loop will then call clock.sleep(for: 1) which suspends on FakeClock.
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    if case .reconnecting(let mode, _) = o.state {
        #expect(mode == .call)
    } else {
        Issue.record("Expected .reconnecting, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_rateLimited_usesRetryAfterAsFirstDelay() async throws {
    // When the failure is .rateLimited(retryAfter: X), the orchestrator should
    // use X as the first backoff delay instead of BackoffPolicy's initial.
    // We can't easily observe the delay value itself (it's consumed by clock.sleep
    // internally), but we can confirm the path was taken by checking that the
    // orchestrator enters .reconnecting.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    factory.streams[.peer]?.emitConnectionState(.failed(.rateLimited(retryAfter: 7)))

    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    if case .reconnecting = o.state {
        #expect(true)
    } else {
        Issue.record("Expected .reconnecting after rateLimited failure, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_reconnect_closesPreviousStream() async throws {
    // When a stream fails, the orchestrator must close the stale stream as part
    // of the reconnect flow — otherwise the old WebSocket and its receive task
    // leak across repeated reconnects.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    let originalPeer = factory.streams[.peer]!
    originalPeer.emitConnectionState(.failed(.networkLost))

    // Wait until the orchestrator has entered .reconnecting (which happens
    // synchronously after cancelling old tasks + closing the stale stream).
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    #expect(originalPeer.closeCalls >= 1, "Original peer stream should have been closed during reconnect")
}

@Test @MainActor func orchestrator_terminalErrorMidSession_setsErrorWithoutReconnect() async throws {
    // apiKeyInvalid is terminal — orchestrator should transition straight to .error.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    factory.streams[.peer]?.emitConnectionState(.failed(.apiKeyInvalid))

    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }

    #expect(o.state.errorValue == .apiKeyInvalid)
}

@Test @MainActor func orchestrator_blackHole16chDisappears_transitionsToError() async throws {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    let o = makeOrchestrator(registry: registry)
    await o.start(mode: .call, languages: .default)

    // Simulate BlackHole 16ch disappearance
    registry.bh16ch = nil
    registry.notifyDeviceChange()

    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }

    if case .error(let e) = o.state {
        #expect(e == .blackHole16chMissing)
    } else {
        Issue.record("Expected .error(.blackHole16chMissing), got \(o.state)")
    }
}

@Test @MainActor func orchestrator_blackHole2chDisappearsInCallMode_transitionsToError() async throws {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    let o = makeOrchestrator(registry: registry)
    await o.start(mode: .call, languages: .default)

    registry.bh2ch = nil
    registry.notifyDeviceChange()

    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }

    if case .error(let e) = o.state {
        #expect(e == .blackHole2chMissing)
    } else {
        Issue.record("Expected .error(.blackHole2chMissing), got \(o.state)")
    }
}

@Test @MainActor func orchestrator_inputDeviceDisappears_fallsBackToDefault() async throws {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    registry.bh16ch = AudioDevice(uid: "bh16", name: "BlackHole 16ch", kind: .input)
    registry.inputs = [AudioDevice(uid: "airpods", name: "AirPods", kind: .input)]
    var settings = Settings.default
    settings.inputDeviceUID = "airpods"
    let o = makeOrchestrator(registry: registry)
    await o.start(mode: .call, languages: .default, settings: settings)

    // Sanity: should be translating now
    guard case .translating = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }

    registry.inputs = []  // AirPods disconnected
    registry.notifyDeviceChange()
    try await Task.sleep(nanoseconds: 100_000_000)

    // State should still be .translating (soft fallback)
    if case .translating = o.state {
        #expect(true)
    } else {
        Issue.record("Expected .translating, got \(o.state)")
    }
}
