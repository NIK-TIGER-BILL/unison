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

    if case .reconnecting(let mode, _, _) = o.state {
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

// MARK: - Empty-close terminal escalation

@Test @MainActor func orchestrator_twoConsecutiveEmptyCloses_escalatesToTerminalApiKeyInvalid() async throws {
    // Two `.failed(receivedAnyData: false)` events on the same speaker
    // within one session are the strongest signal of bad credentials or
    // a disabled account — the server accepts the WS upgrade then drops
    // us before delivering any chunk. The orchestrator must escalate to
    // terminal `.apiKeyInvalid` to break the otherwise-endless retry
    // loop.
    //
    // Use `InstantClock` so the reconnect retry loop completes
    // quickly enough for the test to observe the second failure on
    // the rebuilt stream.
    let instantClock = InstantClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: instantClock)
    await o.start(mode: .call, languages: .default)
    guard case .translating = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }

    // First empty close — orchestrator counter becomes 1, goes to
    // .reconnecting. The InstantClock returns immediately so the
    // reconnect attempt fires and a NEW peer stream is built.
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))

    // Poll until reconnect succeeds (state back to .translating with a
    // fresh stream wired up). Also bail if the orchestrator decided
    // to short-circuit straight to .error.
    for _ in 0..<300 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .translating = o.state { break }
        if case .error = o.state { break }
    }
    guard case .translating = o.state else {
        Issue.record("Expected .translating after reconnect, got \(o.state)")
        return
    }

    // Yield a few times so the observer task on the new stream is
    // actually scheduled before we emit on it. This is important
    // because Task creation doesn't guarantee immediate execution —
    // it requires at least one suspension point on the main actor.
    for _ in 0..<5 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    // Second empty close on the SAME speaker via the rebuilt stream —
    // counter becomes 2 ≥ threshold, must terminate.
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))
    for _ in 0..<300 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }

    #expect(o.state.errorValue == TranslationError.apiKeyInvalid)
}

@Test @MainActor func orchestrator_singleEmptyClose_doesNotEscalateImmediately() async throws {
    // A single empty close must NOT trigger the terminal escalation —
    // it should only set the counter to 1 and let the regular
    // reconnect logic try again. The escalation only fires at the
    // second consecutive empty close.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    if case .error = o.state {
        Issue.record("Single empty close must not escalate to terminal; got \(o.state)")
    }
    if case .reconnecting = o.state {
        #expect(true)
    } else {
        Issue.record("Expected .reconnecting after a single empty close, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_emptyClosesOnDifferentSpeakers_doNotEscalate() async throws {
    // The counter is per-speaker — one empty close on `.me` plus one on
    // `.peer` should NOT trigger the terminal escalation (which fires
    // only at 2 consecutive on the SAME speaker).
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    // Empty close on .peer (counter[.peer] = 1) followed by one on
    // .me (counter[.me] = 1). Neither speaker has hit the threshold
    // of 2, so the orchestrator must remain in .reconnecting rather
    // than escalating to terminal error.
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))
    factory.streams[.me]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))

    // Give the orchestrator time to process both events on the main
    // actor. Two empty closes on different speakers should leave the
    // counter at 1 each — well below the threshold.
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    if case .error(.apiKeyInvalid) = o.state {
        Issue.record("Should not have escalated to terminal — empty closes were on different speakers; got \(o.state)")
    }
}

// MARK: - Persistent timer across reconnects

@Test @MainActor func orchestrator_reconnectingState_carriesOriginalSessionStartedAt() async throws {
    // The popover timer reads `state.sessionStartedAt`. When a stream
    // fails and the orchestrator moves to `.reconnecting`, the timer
    // must keep counting from the user's click. The simplest way to
    // verify is to confirm `.reconnecting` carries the same `startedAt`
    // as the prior `.translating`.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    guard case .translating(_, let startedAt) = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }

    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: true))
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    if case .reconnecting(_, _, let preservedStartedAt) = o.state {
        #expect(preservedStartedAt == startedAt, "Reconnecting must carry the original session start time so the popover timer keeps counting")
    } else {
        Issue.record("Expected .reconnecting, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_reconnectingState_keepsCountingFromOriginalStartedAt() async throws {
    // While in `.reconnecting`, `state.sessionStartedAt` must equal the
    // original `.translating.startedAt` — the popover timer reads this
    // and would snap back to 00:00 if the orchestrator used
    // `clock.now()` here. This is the user-visible "timer keeps
    // ticking from my click" fix without needing to drive the full
    // reconnect-success path.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    guard case .translating(_, let originalStartedAt) = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }

    // Advance the clock so any reset-on-reconnect bug would show up
    // (the bug would replace `startedAt` with `clock.now()` = 5).
    fakeClock.advance(by: 5)

    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: true))
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    let preserved = o.state.sessionStartedAt
    #expect(preserved == originalStartedAt, "Timer must not reset on reconnect — got \(String(describing: preserved)), expected \(originalStartedAt)")
}
