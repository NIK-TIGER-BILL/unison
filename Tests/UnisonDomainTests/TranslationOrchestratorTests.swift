import Foundation
import Testing
@testable import UnisonDomain

@MainActor
private func defaultRegistry() -> MockAudioDeviceRegistry {
    let r = MockAudioDeviceRegistry()
    r.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
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
    transformer: any AudioFormatTransformer = MockAudioFormatTransformer(),
    networkMonitor: any NetworkPathMonitoring = MockNetworkPathMonitor(initial: .satisfied)
) -> TranslationOrchestrator {
    let resolvedRegistry = registry ?? defaultRegistry()
    let resolvedPerms = perms ?? defaultPerms()
    return TranslationOrchestrator(
        micCapture: mic, peerCapture: peer, outputMixer: mixer,
        virtualMicPlayer: bhPlayer, translationFactory: factory,
        permissions: resolvedPerms, deviceRegistry: resolvedRegistry, clock: clock,
        transformer: transformer,
        networkMonitor: networkMonitor
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
    registry.bh2ch = nil
    let o = makeOrchestrator(registry: registry)
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .blackHole2chMissing)
}

@Test @MainActor func orchestrator_startListen_skipsMicAndBH2ch() async throws {
    let mic = MockMicrophoneCapture()
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .denied
    let registry = MockAudioDeviceRegistry()
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

// Regression: capture/engine teardown must NOT run on the main thread.
// CoreAudio HAL teardown (Process Tap aggregate-device destroy,
// AVAudioEngine.stop) is synchronous and can block for seconds — or hang
// if coreaudiod is wedged — doing IPC to coreaudiod. Running it inline on
// the @MainActor `stop()` froze the whole UI on Stop (observed: the app
// hung at `ProcessTapCapture.teardown()` and had to be force-killed).
@Test @MainActor func orchestrator_stop_tearsDownAudioOffMainThread() async throws {
    let mic = MockMicrophoneCapture()
    let o = makeOrchestrator(mic: mic)
    await o.start(mode: .call, languages: .default)
    await o.stop()
    #expect(mic.stopCalls >= 1)
    #expect(mic.stoppedOnMainThread == false,
            "audio teardown ran on the main thread — a blocking CoreAudio stop would freeze the UI")
}

// Regression (unison.log pid=13100 / pid=83933): the synchronous
// CoreAudio HAL teardown (`AVAudioEngine.stop()`, Process-Tap
// aggregate-device destroy) intermittently wedges for a long time —
// especially on a Bluetooth output. Moving it off the main thread keeps
// the UI alive, but `stopAllStreams()` still AWAITED that teardown
// before `stop()` could set `state = .idle`, so a wedge pinned the
// session in `.translating` forever: the Stop button looked dead, the
// UI sat in its stopping state, and capture was already gone. The
// session must reach `.idle` within a bounded budget regardless of the
// HAL — the teardown finishes in the background if it ever recovers.
@Test @MainActor func orchestrator_stop_reachesIdleEvenWhenAudioTeardownWedges() async throws {
    let mixer = MockAudioOutputMixer()
    mixer.blockStopUntilReleased = true   // simulate a wedged engine.stop()
    let o = makeOrchestrator(mixer: mixer, clock: InstantClock())
    await o.start(mode: .listen, languages: .default)

    // Drive stop() concurrently — without the timeout it never returns
    // (parked on the wedged teardown), so we must not `await` it inline.
    let stopTask = Task { await o.stop() }

    // Give the orchestrator bounded main-actor turns to settle to .idle.
    // With the budget it bails the wedged teardown; without it, state
    // stays .translating and this assertion fails fast (no hang).
    for _ in 0..<1000 where o.state != .idle { await Task.yield() }
    #expect(o.state == .idle,
            "stop() never reached .idle — it is still awaiting a wedged CoreAudio teardown")

    mixer.releaseStop()   // let the background teardown finish
    await stopTask
}

// The session can return to `.idle` while a wedged teardown is still
// draining in the background (above). A subsequent stop() must NOT spawn a
// second teardown that calls `mixer.stop()` / Process-Tap destroy
// concurrently with the wedged one — concurrent CoreAudio HAL destroy can
// crash coreaudiod. `stopAllStreams()` chains each teardown behind the
// previous, so the calls stay strictly sequential (where each component's
// stop() is idempotent).
@Test @MainActor func orchestrator_overlappingStops_serializeHALTeardown() async throws {
    let mixer = MockAudioOutputMixer()
    mixer.blockStopUntilReleased = true
    let o = makeOrchestrator(mixer: mixer, clock: InstantClock())

    // Stop #1 returns via the budget timeout; its teardown wedges in mixer.stop().
    await o.start(mode: .listen, languages: .default)
    await o.stop()
    for _ in 0..<1000 where mixer.stopCalls < 1 { await Task.yield() }
    #expect(mixer.stopCalls == 1)
    #expect(o.state == .idle)

    // Restart + stop again while teardown #1 is still wedged. Teardown #2
    // must wait for #1 (chained) instead of calling mixer.stop() concurrently.
    await o.start(mode: .listen, languages: .default)
    await o.stop()
    for _ in 0..<1000 where o.state != .idle { await Task.yield() }
    #expect(o.state == .idle)
    // Spin long enough that a (buggy) concurrent teardown #2 would have
    // reached mixer.stop() on its detached thread. With chaining it stays
    // blocked behind the wedged #1, so the count holds at 1.
    for _ in 0..<1000 { await Task.yield() }
    #expect(mixer.stopCalls == 1,
            "second teardown ran mixer.stop() while the first was still wedged — HAL double-stop hazard")

    // Releasing cascades through the chain → both teardowns run, sequentially.
    mixer.releaseStop()
    for _ in 0..<2000 where mixer.stopCalls < 2 { await Task.yield() }
    #expect(mixer.stopCalls == 2, "chained teardowns should each run mixer.stop() exactly once")
}

// The other half of the fix: start()'s wait on a still-draining teardown
// is BOUNDED by the same budget. A regression to an unbounded
// `await pendingTeardown?.value` would hang start() forever on a wedged
// previous stop. start() must reach `.translating` even while teardown #1
// is still wedged.
@Test @MainActor func orchestrator_startAfterWedgedStop_doesNotHang() async throws {
    let mixer = MockAudioOutputMixer()
    mixer.blockStopUntilReleased = true
    let o = makeOrchestrator(mixer: mixer, clock: InstantClock())

    await o.start(mode: .listen, languages: .default)
    await o.stop()
    for _ in 0..<1000 where o.state != .idle { await Task.yield() }
    #expect(o.state == .idle)

    // Restart while teardown #1 is still wedged. Drive it concurrently so a
    // regression (unbounded wait) fails the assertion instead of hanging.
    let startTask = Task { await o.start(mode: .listen, languages: .default) }
    var reached = false
    for _ in 0..<1000 {
        if case .translating = o.state { reached = true; break }
        await Task.yield()
    }
    #expect(reached, "start() after a wedged stop did not reach .translating — blocked on the wedged teardown")

    mixer.releaseStop()   // unblock so even a regressed unbounded wait can finish
    await startTask
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

    // Poll for the frame to land — the mic→stream pipeline hops through
    // MainActor (`markMicFrameReceived`, `logMicLevel`, transcript
    // mutations) so a fixed 100 ms sleep is flaky on a contended test
    // machine. Cap at 1s, which is still tight enough to catch a
    // genuinely-broken pipeline.
    let deadline = Date().addingTimeInterval(1.0)
    while Date() < deadline, factory.streams[.me]?.sentFrames.isEmpty != false {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    let outgoing = factory.streams[.me]!.sentFrames
    #expect(outgoing.count == 1, "Expected 1 frame sent to OUT stream, got \(outgoing.count)")
    if !outgoing.isEmpty {
        #expect(outgoing[0].sampleRate == 24_000, "Frame must be at OpenAI wire rate")
        #expect(outgoing[0].format == .int16, "Frame must be wire format Int16")
    }
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
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied)
    )
    await o.start(mode: .call, languages: .default)
    #expect(o.state.errorValue == .apiKeyInvalid)
}

@Test @MainActor func orchestrator_meConnectFailure_tearsDownAlreadyWiredPeerSide() async throws {
    // In `.call` mode the peer stream connects and wires BEFORE the me
    // stream. If me.connect fails, the orchestrator must tear the peer
    // side (and captures/mixer) down — otherwise audio keeps streaming
    // to OpenAI behind a terminal `.error` state, with no way to stop
    // it from the UI (`start()` requires `.idle`).
    final class MeFailsFactory: TranslationStreamFactory, @unchecked Sendable {
        let peerStream = MockTranslationStream(speaker: .peer)
        func make(speaker: Speaker) -> any TranslationStream {
            switch speaker {
            case .peer: return peerStream
            case .me:
                let s = MockTranslationStream(speaker: .me)
                s.connectError = TranslationError.apiKeyInvalid
                return s
            }
        }
    }
    let factory = MeFailsFactory()
    let peerCapture = MockPeerAudioCapture()
    let mixer = MockAudioOutputMixer()
    let o2 = TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: peerCapture,
        outputMixer: mixer,
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: factory,
        permissions: defaultPerms(),
        deviceRegistry: defaultRegistry(),
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied)
    )
    await o2.start(mode: .call, languages: .default)

    #expect(o2.state.errorValue == .apiKeyInvalid)
    #expect(factory.peerStream.closeCalls >= 1, "Peer stream must be closed when me.connect fails mid-start")
    #expect(peerCapture.stopCalls >= 1, "Peer capture must be stopped when start() fails midway")
    #expect(mixer.stopCalls >= 1, "Output mixer must be stopped when start() fails midway")
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
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied)
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

    // Push a .failed event on the peer stream's connectionState.
    // `receivedAnyData: true` is the "transient drop mid-session"
    // signature — we want to verify the regular reconnect path, NOT
    // the empty-close terminal escalation.
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: true))

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
    // When the failure is .rateLimited(retryAfter: 7), the orchestrator must
    // use 7 s as the first backoff delay instead of BackoffPolicy's initial
    // (1 s). Observable via FakeClock: just before the 7 s mark no fresh
    // stream may exist; once virtual time crosses 7 s the retry fires and
    // builds one.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)
    let originalPeer = factory.streams[.peer]

    factory.streams[.peer]?.emitConnectionState(.failed(.rateLimited(retryAfter: 7), receivedAnyData: true))
    for _ in 0..<50 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }
    guard case .reconnecting = o.state else {
        Issue.record("Expected .reconnecting after rateLimited failure, got \(o.state)")
        return
    }
    // Let the retry task park on clock.sleep(7) before advancing.
    try await Task.sleep(nanoseconds: 100_000_000)

    // 6.9 s — BackoffPolicy's 1 s initial would already have fired; the
    // retry-after path must still be waiting.
    fakeClock.advance(by: 6.9)
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(factory.streams[.peer] === originalPeer,
            "Retry fired before retryAfter elapsed — BackoffPolicy initial was used instead of retry-after")

    // Crossing 7 s releases the retry → fresh stream + recovery.
    fakeClock.advance(by: 0.2)
    for _ in 0..<50 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if factory.streams[.peer] !== originalPeer { break }
    }
    #expect(factory.streams[.peer] !== originalPeer,
            "Retry must fire once virtual time crosses the retryAfter deadline")
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
    // Mark as transient drop so we exercise the reconnect path (otherwise
    // the empty-close threshold escalates straight to terminal error).
    originalPeer.emitConnectionState(.failed(.networkLost, receivedAnyData: true))

    // Wait until the orchestrator has entered .reconnecting (which happens
    // synchronously after cancelling old tasks + closing the stale stream).
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }

    #expect(originalPeer.closeCalls >= 1, "Original peer stream should have been closed during reconnect")
}

/// Cancellation-AWARE test clock: like the production `SystemClock`, its
/// `sleep` rides `Task.sleep` and therefore throws `CancellationError`
/// on a cancelled task — but compresses time (1 virtual second = 20 real
/// milliseconds) so backoff delays and watchdog deadlines keep their
/// relative order without slowing the suite. The other mock clocks ignore
/// cancellation entirely, which is how the reconnect-retry-loop
/// self-cancellation bug stayed invisible to them.
final class ScaledRealClock: Clock, @unchecked Sendable {
    func now() -> Date { Date() }
    func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 20_000_000)) // 1s → 20ms
    }
}

@Test @MainActor func orchestrator_midSessionFailure_retriesAndRecovers_underCancellationAwareClock() async throws {
    // Production regression guard: `handleStreamFailure` cancels the failed
    // speaker's pipeline tasks — including the observer task it used to run
    // its retry loop on. With a cancellation-aware clock (= production
    // SystemClock behaviour) the first backoff sleep then threw
    // CancellationError and the session never reconnected, riding the
    // 15 s watchdog into terminal `.error(.networkLost)` on every WS flap.
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: ScaledRealClock())
    await o.start(mode: .call, languages: .default)
    guard case .translating = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }
    // Disarm the no-data watchdog (20 virtual s = 400 real ms here) so it
    // can't race the recovery assertion on a slow machine.
    factory.streams[.peer]?.emitTranscript(
        TranscriptDelta(entryId: UUID(), speaker: .peer, kind: .original, text: "привет", isFinal: false)
    )
    try await Task.sleep(nanoseconds: 20_000_000)

    let originalPeer = factory.streams[.peer]
    originalPeer?.emitConnectionState(.failed(.networkLost, receivedAnyData: true))

    // First backoff delay = 1 virtual s = 20 real ms; the reconnect
    // watchdog = 15 virtual s = 300 real ms. Poll up to 2 s for recovery.
    let deadline = Date().addingTimeInterval(2.0)
    while Date() < deadline {
        if case .translating = o.state, factory.streams[.peer] !== originalPeer { break }
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    guard case .translating = o.state else {
        Issue.record("Retry loop must bring the session back to .translating (did it run on a cancelled task?); got \(o.state)")
        return
    }
    #expect(factory.streams[.peer] !== originalPeer, "Reconnect must build a fresh peer stream via the factory")
    await o.stop()
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

@Test @MainActor func orchestrator_blackHole2chDisappearsInCallMode_transitionsToError() async throws {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
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

    // The soft fallback must not interrupt the session.
    guard case .translating = o.state else {
        Issue.record("Input-device loss must soft-fallback, not interrupt: expected .translating, got \(o.state)")
        return
    }
}

// MARK: - Empty-close terminal escalation

@Test @MainActor func orchestrator_singleEmptyClose_escalatesToTerminalApiKeyInvalid() async throws {
    // A single `.failed(receivedAnyData: false)` event within a session is
    // the strongest signal of bad credentials or a disabled account —
    // the server accepts the WS upgrade then drops us before delivering
    // any chunk. macOS NSURLSession would not close a successful
    // realtime stream this quickly, so this is exclusively a server-
    // side rejection. The orchestrator must escalate to terminal
    // `.apiKeyInvalid` immediately to break the otherwise-endless retry
    // loop.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)
    guard case .translating = o.state else {
        Issue.record("Expected .translating after start, got \(o.state)")
        return
    }

    // First (and only) empty close — counter becomes 1 ≥ threshold,
    // must terminate immediately. No reconnect attempts.
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }

    #expect(o.state.errorValue == TranslationError.apiKeyInvalid)
}

@Test @MainActor func orchestrator_releasesAudioActivityToken_onTerminalError() async throws {
    // C1 regression: the App Nap / latency-critical activity token must be
    // released on EVERY session-end path — including a terminal auto-failure,
    // not just a user-initiated stop(). Otherwise a backgrounded session that
    // errored (WiFi drop, bad key, no data) keeps pinning high-precision
    // timers and blocking system sleep until the user manually presses Stop.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)
    #expect(o.isHoldingAudioActivity, "token should be held while translating")

    // Drive a terminal error (single empty close → .apiKeyInvalid), which
    // goes through stopAllStreams() but NOT stop().
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }
    guard case .error = o.state else {
        Issue.record("Expected terminal .error, got \(o.state)")
        return
    }
    #expect(o.isHoldingAudioActivity == false,
            "App Nap token must be released when the session auto-fails to a terminal error")
}

@Test @MainActor func orchestrator_emptyCloseOnAnySpeaker_escalates() async throws {
    // With threshold=1, an empty close on EITHER speaker terminates the
    // session immediately. Previously the test covered the per-speaker
    // counter not crossing the threshold of 2; now even a single empty
    // close on `.me` is terminal. Verifying both speakers exercise the
    // same escalation path keeps the regression coverage symmetric.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)

    factory.streams[.me]?.emitConnectionState(.failed(.networkLost, receivedAnyData: false))
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }

    #expect(o.state.errorValue == TranslationError.apiKeyInvalid)
}

// MARK: - Reconnect watchdog

@Test @MainActor func orchestrator_reconnectWatchdog_firesIfReconnectingForTooLong() async throws {
    // If the orchestrator stays in `.reconnecting` without ever
    // recovering for longer than the watchdog window, it must force
    // terminal `.error(.apiKeyInvalid)` — even when the empty-close
    // counter can't see the failure (e.g. the stream hangs after the
    // handshake instead of closing). Drive the FakeClock past the
    // watchdog deadline and confirm the state moves to .error.
    //
    // To keep the retry loop from racing the watchdog (which can
    // succeed instantly on the no-op MockTranslationStream and would
    // transition us back to `.translating` before the watchdog body
    // gets to inspect state), arrange for every reconnected stream
    // to throw on connect — that keeps the loop suspended in the
    // backoff sleep and lets the watchdog be the first to advance.
    let fakeClock = FakeClock(now: epochDate(0))
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, clock: fakeClock)
    await o.start(mode: .call, languages: .default)
    // After start, future streams (rebuilt during reconnect attempts)
    // will fail to connect.
    factory.nextConnectError = TranslationError.networkLost

    // Use `receivedAnyData: true` so the empty-close path doesn't fire
    // first — we want the watchdog to be the one to escalate.
    factory.streams[.peer]?.emitConnectionState(.failed(.networkLost, receivedAnyData: true))
    for _ in 0..<20 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .reconnecting = o.state { break }
    }
    guard case .reconnecting = o.state else {
        Issue.record("Expected .reconnecting before watchdog fires, got \(o.state)")
        return
    }

    // Give the watchdog Task body time to actually start its
    // `clock.sleep(15)` and register a deadline in FakeClock.pending.
    // Otherwise our `advance(by: 20)` below races the Task creation
    // and may fire before the watchdog has anything scheduled.
    for _ in 0..<30 {
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    // Advance past the watchdog window. The FakeClock releases the
    // watchdog's sleep continuation, which then transitions state to
    // .error after observing we're still in .reconnecting.
    fakeClock.advance(by: 20)

    for _ in 0..<200 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if case .error = o.state { break }
    }
    #expect(o.state.errorValue == TranslationError.networkLost,
            "Reconnect watchdog must force terminal .networkLost (it fires after data has flowed; a fresh credential failure would have escalated to .apiKeyInvalid via the empty-close counter long before the watchdog); got \(o.state)")
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

// MARK: - ConnectivityHealth per-stream tracking

@Test @MainActor func orchestrator_initialHealth_isHealthy() {
    let o = makeOrchestrator()
    #expect(o.connectivityHealth == .healthy)
}

@Test @MainActor func orchestrator_micFramesAudible_noDelta_3s_marksSlow() async throws {
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let clock = ManualClock()
    let o = makeOrchestrator(mic: mic, factory: factory, clock: clock)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)

    // Audible mic frame (RMS > 0.001 because samples are non-zero)
    let pcm = Data(repeating: 0x40, count: 4 * 4_800)  // 4800 float32 samples
    let frame = AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32)
    mic.emit(frame)
    try? await Task.sleep(nanoseconds: 100_000_000)

    // Advance time past the 3 s slow threshold without any delta arriving.
    clock.advance(by: 3.5)
    try? await Task.sleep(nanoseconds: 100_000_000)

    #expect(o.connectivityHealth == .slow)
}

@Test @MainActor func orchestrator_deltaArrival_clearsSlow() async throws {
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let clock = ManualClock()
    let o = makeOrchestrator(mic: mic, factory: factory, clock: clock)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)

    let pcm = Data(repeating: 0x40, count: 4 * 4_800)
    mic.emit(AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32))
    // Give the mic frame time to propagate through the capture
    // pipeline (task1 → MainActor.run → markMicFrameReceived) before
    // advancing time. Without this yield, the slow-detection
    // iteration that fires on advance can race ahead of the mic
    // frame and see `lastAudibleMicAt == nil`, never marking slow.
    try? await Task.sleep(nanoseconds: 100_000_000)
    clock.advance(by: 3.5)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(o.connectivityHealth == .slow)

    // Simulate a delta arriving on the me-stream.
    factory.streams[.me]?.emitTranscript(
        TranscriptDelta(entryId: UUID(), speaker: .me, kind: .original, text: "ок", isFinal: false)
    )
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(o.connectivityHealth == .healthy)
}

// MARK: - NetworkMonitor → .paused / auto-resume

@Test @MainActor func orchestrator_networkUnsatisfied_transitionsToPaused() async throws {
    let netMon = MockNetworkPathMonitor(initial: .satisfied)
    let o = makeOrchestrator(networkMonitor: netMon)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)
    guard case .translating = o.state else {
        Issue.record("Expected .translating, got \(o.state)")
        return
    }
    netMon.simulate(.unsatisfied)
    try? await Task.sleep(nanoseconds: 100_000_000)
    if case .paused(_, _, _, let reason) = o.state {
        #expect(reason == .networkLost)
    } else {
        Issue.record("Expected .paused(.networkLost), got \(o.state)")
    }
}

@Test @MainActor func orchestrator_networkSatisfiedWhilePaused_resumes() async throws {
    let netMon = MockNetworkPathMonitor(initial: .satisfied)
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(factory: factory, networkMonitor: netMon)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)

    netMon.simulate(.unsatisfied)
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard case .paused = o.state else {
        Issue.record("Expected .paused after unsatisfied, got \(o.state)")
        return
    }

    netMon.simulate(.satisfied)
    try? await Task.sleep(nanoseconds: 300_000_000)
    if case .translating = o.state {
        // ok
    } else {
        Issue.record("Expected .translating after network restored, got \(o.state)")
    }
}

@Test @MainActor func orchestrator_pauseRecoveryWatchdog_firesAfter60s() async throws {
    let netMon = MockNetworkPathMonitor(initial: .satisfied)
    let clock = ManualClock()
    let o = makeOrchestrator(clock: clock, networkMonitor: netMon)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)
    netMon.simulate(.unsatisfied)
    try? await Task.sleep(nanoseconds: 100_000_000)
    if case .paused = o.state {} else {
        Issue.record("Expected .paused, got \(o.state)")
        return
    }

    // Advance virtual time past 60 s without the network returning.
    clock.advance(by: 65)
    try? await Task.sleep(nanoseconds: 200_000_000)

    if case .error(.networkLost) = o.state {
        // ok
    } else {
        Issue.record("Expected terminal .error(.networkLost) after 60s, got \(o.state)")
    }
}

// MARK: - AudioRingBuffer flush on stream reconnect

@Test @MainActor func orchestrator_streamReconnect_flushesAudioBuffer() async throws {
    // FakeClock keeps the reconnect retry loop's `clock.sleep` from
    // throwing on cancellation: `withCheckedThrowingContinuation` is
    // not a cancellation point, so the suspended retry survives the
    // observer task's self-cancellation in `handleStreamFailure`.
    // After advancing the clock past the backoff delay the retry
    // proceeds, instantiates a fresh me-stream, and (per the buffer
    // wiring) drains the ring buffer onto it BEFORE wiring live mic.
    let fakeClock = FakeClock(now: epochDate(0))
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(mic: mic, factory: factory, clock: fakeClock)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 100_000_000)

    let initialStream = factory.streams[.me]!
    // Send a few frames — they go to the live stream AND into the
    // ring buffer.
    for _ in 0..<5 {
        mic.emit(AudioFrame(pcm: Data(repeating: 0x40, count: 4 * 4_800), sampleRate: 48_000, channels: 1, format: .float32))
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    let preReconnectCount = initialStream.sentFrames.count
    #expect(preReconnectCount >= 5)

    // Simulate a mid-session drop (`receivedAnyData: true` so we
    // exercise the reconnect path instead of the empty-close terminal
    // escalation). The factory hands out a fresh stream on the next
    // `make(...)` call, and the orchestrator must drain the ring
    // buffer into that new stream BEFORE wiring live mic.
    initialStream.emitConnectionState(.failed(.networkLost, receivedAnyData: true))

    // Wait for the orchestrator to enter `.reconnecting`. The retry
    // loop then suspends inside `fakeClock.sleep(for: 1)`.
    for _ in 0..<50 {
        try? await Task.sleep(nanoseconds: 20_000_000)
        if case .reconnecting = o.state { break }
    }
    guard case .reconnecting = o.state else {
        Issue.record("Expected .reconnecting after stream failure, got \(o.state)")
        return
    }
    // Advance past the first backoff delay so the retry actually
    // attempts to reconnect.
    fakeClock.advance(by: 1.5)

    var newStream: MockTranslationStream = initialStream
    for _ in 0..<200 {
        try? await Task.sleep(nanoseconds: 20_000_000)
        if let candidate = factory.streams[.me], candidate !== initialStream {
            newStream = candidate
            if newStream.sentFrames.count >= 5 { break }
        }
    }
    #expect(newStream !== initialStream, "After reconnect, factory.streams[.me] should point to a new stream (state=\(o.state))")
    // The flush should have moved buffered frames (5 we just sent)
    // into the new stream's sentFrames before any new mic frame
    // arrives.
    #expect(newStream.sentFrames.count >= 5)
}

// MARK: - Iter-1 / iter-2 review regressions

/// Iter-1 #1: rewriting `evaluateSlowDetection` introduced a demote-on-silent
/// path so `.slow` is no longer sticky after the user stops talking.
@Test @MainActor func orchestrator_slowState_demotesToHealthyWhenUserStopsTalking() async throws {
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let clock = ManualClock()
    let o = makeOrchestrator(mic: mic, factory: factory, clock: clock)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)

    // Phase 1: user is speaking, no delta → .slow
    let pcm = Data(repeating: 0x40, count: 4 * 4_800)
    mic.emit(AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32))
    try? await Task.sleep(nanoseconds: 100_000_000)
    clock.advance(by: 3.5)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(o.connectivityHealth == .slow, "Setup: expected .slow before demote test (got \(o.connectivityHealth))")

    // Phase 2: user falls silent (no more audible frames). After the
    // userSpeakingWindowSeconds elapses, the slow loop must demote
    // .slow back to .healthy on its next tick.
    clock.advance(by: 5)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(o.connectivityHealth == .healthy, "Expected .slow → .healthy after user stops talking (got \(o.connectivityHealth))")
}

/// Iter-2 #2: re-arming the no-data watchdog and resetting aliveness latches
/// on resume must NOT leave stale `lastDeltaAtBySpeaker` timestamps that
/// trigger phantom `.slow` after the recovering-flash window closes.
@Test @MainActor func orchestrator_resume_doesNotFlashSlowAfterRecoveringWindow() async throws {
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let netMon = MockNetworkPathMonitor(initial: .satisfied)
    let clock = ManualClock()
    let o = makeOrchestrator(mic: mic, factory: factory, clock: clock, networkMonitor: netMon)
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)

    // Speak + drive a delta so lastDeltaAtBySpeaker[.me] gets stamped
    // BEFORE the pause.
    let pcm = Data(repeating: 0x40, count: 4 * 4_800)
    mic.emit(AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32))
    try? await Task.sleep(nanoseconds: 50_000_000)
    factory.streams[.me]?.emitTranscript(
        TranscriptDelta(entryId: UUID(), speaker: .me, kind: .original, text: "x", isFinal: false)
    )
    try? await Task.sleep(nanoseconds: 50_000_000)

    // Pause + age the pre-pause delta way past slowThresholdSeconds
    // while paused (pretend the user was offline for 30s).
    netMon.simulate(.unsatisfied)
    try? await Task.sleep(nanoseconds: 100_000_000)
    clock.advance(by: 30)

    // Resume. Right after the resume's `.recovering` window closes,
    // the slow loop must NOT see the 30 s-old pre-pause timestamp
    // and flip the session to `.slow` (iter-2 finding). To exercise
    // the bug we must drive userIsSpeaking=true post-resume —
    // otherwise evaluateSlowDetection's silent-speaker early-return
    // makes the test vacuous (iter-3 review finding).
    netMon.simulate(.satisfied)
    try? await Task.sleep(nanoseconds: 300_000_000)
    // Advance past the 2 s recovering-flash window.
    clock.advance(by: 3)
    try? await Task.sleep(nanoseconds: 200_000_000)
    // Emit a fresh post-resume mic frame so the slow loop's
    // userIsSpeaking gate flips to true on the NEXT tick. Without
    // this, the loop early-returns and never gets the chance to
    // observe stale lastDeltaAtBySpeaker.
    mic.emit(AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32))
    try? await Task.sleep(nanoseconds: 200_000_000)
    // Tick the slow loop once.
    clock.advance(by: 1)
    try? await Task.sleep(nanoseconds: 200_000_000)

    // The post-resume pipeline is fresh — without the
    // lastDeltaAtBySpeaker reset, the loop would see (now -
    // pre_pause_delta) >> 3 s and fire .slow. WITH the reset,
    // lastDeltaAtBySpeaker[.me] is nil and the fallback measures
    // staleness from lastAudibleMicAt (just stamped fresh by the
    // emit above), so stale=false and health stays .healthy.
    #expect(o.connectivityHealth != .slow, "Post-resume health should not phantom-flash .slow (got \(o.connectivityHealth))")
}

/// Iter-1 #11: an empty `.translated` delta (handshake / partial reconstruct)
/// must NOT clear `translationAtRisk` — only real content delivery proves
/// the translation arrived.
@Test @MainActor func transcriptStore_emptyTranslatedDelta_doesNotClearAtRisk() {
    let store = TranscriptStore()
    let id = UUID()
    // Seed an in-flight entry with original but no translation.
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .original, text: "Привет", isFinal: false))
    store.markActiveEntriesAtRisk()
    #expect(store.entries.first?.translationAtRisk == true, "Setup: entry must be flagged at-risk")

    // Empty `.translated` delta arrives — flag must persist.
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "", isFinal: false))
    #expect(store.entries.first?.translationAtRisk == true, "Empty translated delta must NOT clear the flag")

    // Non-empty `.translated` delta DOES clear it.
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "Hello", isFinal: false))
    #expect(store.entries.first?.translationAtRisk == false, "Non-empty translated delta must clear the flag")
}

/// Stream whose `connect()` parks until the test releases it — lets a
/// test freeze the orchestrator mid-resume deterministically instead of
/// racing real-time sleeps against the resume pipeline.
final class GatedConnectStream: TranslationStream, @unchecked Sendable {
    let transcripts: AsyncStream<TranscriptDelta> = AsyncStream { _ in }
    let output: AsyncStream<AudioFrame> = AsyncStream { _ in }
    let connectionState: AsyncStream<ConnectionState> = AsyncStream { _ in }
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var _closeCalls = 0
    var closeCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return _closeCalls
    }

    func connect(target: Language) async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock(); gate = c; lock.unlock()
        }
    }

    func releaseConnect() {
        lock.lock(); let g = gate; gate = nil; lock.unlock()
        g?.resume()
    }

    func send(_ frame: AudioFrame) async {}
    func close() async { recordClose() }
    private func recordClose() {
        lock.lock(); _closeCalls += 1; lock.unlock()
    }
}

/// Factory that switches from normal mock streams to gated ones on demand.
final class GateSwitchFactory: TranslationStreamFactory, @unchecked Sendable {
    let normal = MockTranslationStreamFactory()
    var gateNext = false
    private(set) var gated: [GatedConnectStream] = []
    func make(speaker: Speaker) -> any TranslationStream {
        if gateNext {
            let s = GatedConnectStream()
            gated.append(s)
            return s
        }
        return normal.make(speaker: speaker)
    }
}

/// Iter-2 #1: a network drop arriving while resume is in flight
/// (state == `.paused(.awaitingNetwork)`) must re-enter `.networkLost`
/// so the resumeStreams reentrancy guard observes the state change
/// and aborts the half-resumed pipeline. The resume is FROZEN inside
/// `connect()` via a gated stream, so the drop deterministically lands
/// mid-resume — the earlier version raced real-time sleeps and passed
/// even with the regression present (the tolerated `.translating`
/// branch was exactly the regression's outcome).
@Test @MainActor func orchestrator_dropDuringResume_transitionsBackToNetworkLost() async throws {
    let netMon = MockNetworkPathMonitor(initial: .satisfied)
    let factory = GateSwitchFactory()
    let o = TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: factory,
        permissions: defaultPerms(),
        deviceRegistry: defaultRegistry(),
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: netMon
    )
    await o.start(mode: .test, languages: .default)
    try? await Task.sleep(nanoseconds: 50_000_000)

    netMon.simulate(.unsatisfied)
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard case .paused(_, _, _, .networkLost) = o.state else {
        Issue.record("Setup: expected .paused(.networkLost), got \(o.state)")
        return
    }

    // Resume — the fresh me-stream's connect() parks on the gate, so the
    // orchestrator is reliably stuck in `.paused(.awaitingNetwork)`.
    factory.gateNext = true
    netMon.simulate(.satisfied)
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if !factory.gated.isEmpty { break }
    }
    guard let gatedStream = factory.gated.first else {
        Issue.record("Resume never reached connect() — gated stream missing")
        return
    }
    guard case .paused(_, _, _, .awaitingNetwork) = o.state else {
        Issue.record("Expected .paused(.awaitingNetwork) mid-resume, got \(o.state)")
        return
    }

    // Drop arrives while resume is parked — must flip back to
    // `.networkLost`, NOT silently no-op because the state already
    // matches `.paused`.
    netMon.simulate(.unsatisfied)
    try? await Task.sleep(nanoseconds: 100_000_000)
    guard case .paused(_, _, _, .networkLost) = o.state else {
        Issue.record("Mid-resume drop was swallowed: expected .paused(.networkLost), got \(o.state)")
        return
    }

    // Release the parked connect — the resume's reentrancy guard must
    // observe the state change, abort, and close the half-connected
    // stream instead of wiring it into a phantom `.translating`.
    gatedStream.releaseConnect()
    for _ in 0..<100 {
        try await Task.sleep(nanoseconds: 10_000_000)
        if gatedStream.closeCalls >= 1 { break }
    }
    #expect(gatedStream.closeCalls >= 1, "Aborted resume must close the half-connected stream")
    if case .paused(_, _, _, .networkLost) = o.state {
        // Still paused on the dead network — correct.
    } else {
        Issue.record("State must remain .paused(.networkLost) after aborted resume, got \(o.state)")
    }
}
