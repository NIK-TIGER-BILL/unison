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
