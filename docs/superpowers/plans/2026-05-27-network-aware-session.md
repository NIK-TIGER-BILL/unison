# Connectivity-aware session implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Unison resilient to flaky / dropped internet during video-conference translation: visible "slow network" indicator, auto-resume after sustained outage, transparent recovery for sub-3-second blips via a mic-audio ring buffer, and clear marking of phrases whose translation was lost mid-stream.

**Architecture:** Two orthogonal axes on the existing orchestrator. (1) `SessionState` gains a `.paused(reason:)` case driven by `NWPathMonitor` for full-disconnect events. (2) A new `ConnectivityHealth` enum (`.healthy / .slow / .recovering`) tracks per-WS-stream degradation while the session is `.translating`. A 3-second `AudioRingBuffer` per outgoing stream replays mic audio across brief WS flaps. The popover and transcript control pill consume the aggregate of these axes; the menubar icon is intentionally untouched.

**Tech Stack:** Swift 6 (language mode pinned to v5 — see `Package.swift`), `Network.framework` (`NWPathMonitor`), AVFoundation, SwiftUI, Swift Testing.

---

## Task 1: Add `.paused` to `SessionState` + `PauseReason`

**Files:**
- Modify: `Sources/UnisonDomain/SessionState.swift`
- Test: `Tests/UnisonDomainTests/SessionStateTests.swift`

- [ ] **Step 1: Read the current `SessionState`**

Read `Sources/UnisonDomain/SessionState.swift` to confirm the current shape, especially `isActive`, `activeMode`, and `sessionStartedAt` helpers. They each need a new case.

- [ ] **Step 2: Write failing tests for the new case**

Append to `Tests/UnisonDomainTests/SessionStateTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@Test func sessionState_pausedNetworkLost_isActive() {
    let started = Date()
    let state = SessionState.paused(
        mode: .call, since: Date(), startedAt: started, reason: .networkLost
    )
    #expect(state.isActive == true)
    #expect(state.activeMode == .call)
    #expect(state.sessionStartedAt == started)
}

@Test func sessionState_pausedAwaitingNetwork_carriesStartedAt() {
    let started = Date().addingTimeInterval(-30)
    let state = SessionState.paused(
        mode: .listen, since: Date(), startedAt: started, reason: .awaitingNetwork
    )
    #expect(state.activeMode == .listen)
    #expect(state.sessionStartedAt == started)
}

@Test func pauseReason_equatable() {
    #expect(PauseReason.networkLost == PauseReason.networkLost)
    #expect(PauseReason.networkLost != PauseReason.awaitingNetwork)
}
```

- [ ] **Step 3: Run tests — they should fail with "Type 'SessionState' has no member 'paused'"**

```bash
swift test --filter SessionStateTests
```

Expected: 3 compile errors referring to `.paused` and `PauseReason`.

- [ ] **Step 4: Add the case + helpers**

Edit `Sources/UnisonDomain/SessionState.swift`:

```swift
public enum SessionState: Sendable, Equatable {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    /// Network-level pause. WS streams are closed, mic + peer captures
    /// are stopped, and we're waiting for the path to come back. Set
    /// by the orchestrator in response to `NWPathMonitor` reporting
    /// `unsatisfied`; cleared by the same monitor reporting
    /// `satisfied`. `.reconnecting` is reserved for WS-level flap
    /// inside an otherwise-healthy network.
    case paused(mode: SessionMode, since: Date, startedAt: Date, reason: PauseReason)
    case reconnecting(mode: SessionMode, since: Date, startedAt: Date)
    case error(TranslationError)

    public var isActive: Bool {
        switch self {
        case .connecting, .translating, .paused, .reconnecting: true
        case .idle, .error: false
        }
    }

    public var activeMode: SessionMode? {
        switch self {
        case .connecting(let m),
             .translating(let m, _),
             .paused(let m, _, _, _),
             .reconnecting(let m, _, _): m
        case .idle, .error: nil
        }
    }

    public var sessionStartedAt: Date? {
        switch self {
        case .translating(_, let s),
             .paused(_, _, let s, _),
             .reconnecting(_, _, let s): s
        case .idle, .connecting, .error: nil
        }
    }
}

/// Reason the orchestrator entered `.paused`. Distinct from
/// `TranslationError` because `.paused` is recoverable — the session
/// is still alive and will auto-resume when the network returns.
public enum PauseReason: Sendable, Equatable {
    /// `NWPathMonitor` reported `.unsatisfied`. WS streams torn down,
    /// captures halted. UI shows "Нет интернета. Ждём…".
    case networkLost
    /// Network returned (`NWPathMonitor` → `.satisfied`) and we're in
    /// the middle of re-establishing streams. Brief transitional
    /// state; UI shows "Возобновляем…".
    case awaitingNetwork
}
```

- [ ] **Step 5: Run tests to confirm pass**

```bash
swift test --filter SessionStateTests
```

Expected: all 3 new tests pass plus the existing SessionState tests stay green.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/SessionState.swift Tests/UnisonDomainTests/SessionStateTests.swift
git commit -m "feat(domain): add SessionState.paused(reason:) for NWPath-driven outages"
```

---

## Task 2: `ConnectivityHealth` enum + aggregation

**Files:**
- Create: `Sources/UnisonDomain/ConnectivityHealth.swift`
- Create: `Tests/UnisonDomainTests/ConnectivityHealthTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/ConnectivityHealthTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@Test func health_aggregate_allHealthy_isHealthy() {
    #expect(ConnectivityHealth.aggregate(.healthy, .healthy) == .healthy)
}

@Test func health_aggregate_anySlow_isSlow() {
    #expect(ConnectivityHealth.aggregate(.healthy, .slow) == .slow)
    #expect(ConnectivityHealth.aggregate(.slow, .healthy) == .slow)
    #expect(ConnectivityHealth.aggregate(.slow, .slow) == .slow)
}

@Test func health_aggregate_recoveringWithHealthy_isRecovering() {
    // Recovering wins over healthy — UI surfaces the flash even if
    // one side is already steady.
    #expect(ConnectivityHealth.aggregate(.recovering, .healthy) == .recovering)
    #expect(ConnectivityHealth.aggregate(.healthy, .recovering) == .recovering)
}

@Test func health_aggregate_slowBeatsRecovering() {
    // Slow is the worse signal — keep it visible even if one side
    // recently came back.
    #expect(ConnectivityHealth.aggregate(.slow, .recovering) == .slow)
}

@Test func health_aggregateSingleton_returnsInput() {
    #expect(ConnectivityHealth.aggregate(.healthy) == .healthy)
    #expect(ConnectivityHealth.aggregate(.slow) == .slow)
    #expect(ConnectivityHealth.aggregate(.recovering) == .recovering)
}
```

- [ ] **Step 2: Run tests — fail with "Cannot find 'ConnectivityHealth'"**

```bash
swift test --filter ConnectivityHealthTests
```

- [ ] **Step 3: Create the enum**

Create `Sources/UnisonDomain/ConnectivityHealth.swift`:

```swift
import Foundation

/// Orthogonal "quality of service" dimension that the orchestrator
/// publishes alongside `SessionState`. Only meaningful when
/// `SessionState == .translating`; the UI ignores it in any other
/// state (`.paused` / `.reconnecting` / `.error` already speak for
/// themselves).
///
/// Computed per outgoing WS stream (me / peer) and aggregated via
/// `aggregate(_:_:)` for the main popover + control-pill indicator.
/// The diagnostic dialog reads the per-stream value directly so
/// asymmetric failures ("me-stream healthy, peer-stream slow") stay
/// debuggable.
public enum ConnectivityHealth: Sendable, Equatable {
    /// Deltas are flowing, nothing to surface.
    case healthy
    /// User is speaking (mic RMS > 0.001 in the last second) but the
    /// server hasn't returned any delta in ≥3 s. WS is still open —
    /// this is "slow", not "dead".
    case slow
    /// Stream just reconnected. UI shows a brief "Связь восстановлена"
    /// flash for 2 s before reverting to `.healthy` on the next delta
    /// (or the timer expiring, whichever comes first).
    case recovering

    /// Aggregate per-stream health into one overall value for UI.
    /// `slow` dominates (worst signal wins); `recovering` beats
    /// `healthy` so the flash is visible even if one side is steady.
    public static func aggregate(_ a: ConnectivityHealth, _ b: ConnectivityHealth) -> ConnectivityHealth {
        if a == .slow || b == .slow { return .slow }
        if a == .recovering || b == .recovering { return .recovering }
        return .healthy
    }

    /// Single-stream pass-through, used in `.test` / `.listen` modes
    /// where only one of the two pipelines is active.
    public static func aggregate(_ a: ConnectivityHealth) -> ConnectivityHealth {
        a
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter ConnectivityHealthTests
```

Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/ConnectivityHealth.swift Tests/UnisonDomainTests/ConnectivityHealthTests.swift
git commit -m "feat(domain): add ConnectivityHealth enum + per-stream aggregation"
```

---

## Task 3: `NetworkPathMonitoring` protocol + `NetworkMonitor` actor

**Files:**
- Create: `Sources/UnisonSystem/NetworkMonitor.swift`
- Create: `Tests/UnisonSystemTests/NetworkMonitorTests.swift`

The real `NWPathMonitor` is hard to test directly (no public API to push fake paths). We define a protocol so the orchestrator can swap in a mock for tests; the real implementation wraps `NWPathMonitor` and bridges its callback to an `AsyncStream`.

- [ ] **Step 1: Write the failing test for the protocol contract**

Create `Tests/UnisonSystemTests/NetworkMonitorTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonSystem

@Test func mockNetworkMonitor_publishesStatusUpdates() async {
    let monitor = MockNetworkPathMonitor(initial: .satisfied)
    var observed: [NetworkPathStatus] = []
    let task = Task {
        for await status in monitor.statusStream {
            observed.append(status)
            if observed.count == 3 { break }
        }
    }
    // First yield is the initial status.
    try? await Task.sleep(nanoseconds: 50_000_000)
    monitor.simulate(.unsatisfied)
    monitor.simulate(.satisfied)
    _ = await task.value
    #expect(observed == [.satisfied, .unsatisfied, .satisfied])
}

@Test func mockNetworkMonitor_currentStatusReflectsLatest() {
    let monitor = MockNetworkPathMonitor(initial: .satisfied)
    #expect(monitor.currentStatus == .satisfied)
    monitor.simulate(.unsatisfied)
    #expect(monitor.currentStatus == .unsatisfied)
}
```

- [ ] **Step 2: Run — fails with missing types**

```bash
swift test --filter NetworkMonitorTests
```

- [ ] **Step 3: Implement protocol + real monitor + mock**

Create `Sources/UnisonSystem/NetworkMonitor.swift`:

```swift
import Foundation
import Network

/// Coarse-grained system-network status that the orchestrator
/// subscribes to. Distinct from `NWPath.Status` so callers don't
/// have to import `Network` or pattern-match on every variant — for
/// our purposes there are only two states that matter.
public enum NetworkPathStatus: Sendable, Equatable {
    /// The system has a path to the public internet. WS connect
    /// attempts make sense.
    case satisfied
    /// No usable path (WiFi off, ethernet unplugged, airplane mode,
    /// or `requiresConnection` / `unsatisfied`). WS connect
    /// attempts will fail; the orchestrator should pause.
    case unsatisfied
}

/// Abstraction over `NWPathMonitor` so the orchestrator's tests can
/// drive deterministic path transitions without touching the real
/// system monitor (which has no public test seam).
public protocol NetworkPathMonitoring: AnyObject, Sendable {
    /// Latest observed status. Reflects the last value emitted on
    /// `statusStream`.
    var currentStatus: NetworkPathStatus { get }
    /// Hot stream of status transitions. The first yield is the
    /// current status so subscribers don't have to call
    /// `currentStatus` separately on attach.
    var statusStream: AsyncStream<NetworkPathStatus> { get }
}

/// Production implementation backed by `Network.framework`'s
/// `NWPathMonitor`. Single instance per process — `NWPathMonitor`
/// itself is the system-wide path watcher; spinning up multiple is
/// wasteful but not harmful.
public final class NetworkMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.unison.NetworkMonitor", qos: .utility)
    private let continuation: AsyncStream<NetworkPathStatus>.Continuation
    public let statusStream: AsyncStream<NetworkPathStatus>
    /// Stored separately from the stream so synchronous callers can
    /// read the latest status without driving the stream. Mutated on
    /// the monitor's queue; reads on any thread are racy by tens of
    /// milliseconds but that's fine — the orchestrator subscribes to
    /// the stream for authoritative transitions.
    private var _currentStatus: NetworkPathStatus = .satisfied

    public var currentStatus: NetworkPathStatus { _currentStatus }

    public init() {
        var continuation: AsyncStream<NetworkPathStatus>.Continuation!
        self.statusStream = AsyncStream { continuation = $0 }
        self.continuation = continuation

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status: NetworkPathStatus = path.status == .satisfied
                ? .satisfied
                : .unsatisfied
            self._currentStatus = status
            self.continuation.yield(status)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        continuation.finish()
    }
}

/// Test-only mock. Hold a reference, call `simulate(_:)` to push a
/// new status onto the stream and update `currentStatus`.
public final class MockNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    public let statusStream: AsyncStream<NetworkPathStatus>
    private let continuation: AsyncStream<NetworkPathStatus>.Continuation
    private var _currentStatus: NetworkPathStatus
    public var currentStatus: NetworkPathStatus { _currentStatus }

    public init(initial: NetworkPathStatus) {
        var continuation: AsyncStream<NetworkPathStatus>.Continuation!
        self.statusStream = AsyncStream { continuation = $0 }
        self.continuation = continuation
        self._currentStatus = initial
        // First yield is the initial status so subscribers don't
        // have to read `currentStatus` separately on attach.
        continuation.yield(initial)
    }

    public func simulate(_ status: NetworkPathStatus) {
        _currentStatus = status
        continuation.yield(status)
    }

    public func finish() {
        continuation.finish()
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter NetworkMonitorTests
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonSystem/NetworkMonitor.swift Tests/UnisonSystemTests/NetworkMonitorTests.swift
git commit -m "feat(system): NetworkMonitor wrapping NWPathMonitor + test-mock protocol"
```

---

## Task 4: `AudioRingBuffer`

**Files:**
- Create: `Sources/UnisonAudio/AudioRingBuffer.swift`
- Create: `Tests/UnisonAudioTests/AudioRingBufferTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/UnisonAudioTests/AudioRingBufferTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonAudio
@testable import UnisonDomain

private func frame(_ id: UInt8) -> AudioFrame {
    AudioFrame(pcm: Data([id, id, id, id]), sampleRate: 24_000, channels: 1, format: .int16)
}

@Test func ringBuffer_appendUnderCapacity_returnsAllInOrder() {
    let buf = AudioRingBuffer(maxFrames: 4)
    buf.append(frame(1))
    buf.append(frame(2))
    buf.append(frame(3))
    let drained = buf.drain()
    #expect(drained.map { $0.pcm[0] } == [1, 2, 3])
}

@Test func ringBuffer_appendOverCapacity_dropsOldest() {
    let buf = AudioRingBuffer(maxFrames: 3)
    buf.append(frame(1))
    buf.append(frame(2))
    buf.append(frame(3))
    buf.append(frame(4))  // pushes 1 out
    buf.append(frame(5))  // pushes 2 out
    #expect(buf.drain().map { $0.pcm[0] } == [3, 4, 5])
}

@Test func ringBuffer_drainEmptiesBuffer() {
    let buf = AudioRingBuffer(maxFrames: 4)
    buf.append(frame(1))
    _ = buf.drain()
    #expect(buf.drain().isEmpty)
}

@Test func ringBuffer_clearEmpties() {
    let buf = AudioRingBuffer(maxFrames: 4)
    buf.append(frame(1))
    buf.append(frame(2))
    buf.clear()
    #expect(buf.drain().isEmpty)
}
```

- [ ] **Step 2: Run — fails with missing type**

```bash
swift test --filter AudioRingBufferTests
```

- [ ] **Step 3: Implement the buffer**

Create `Sources/UnisonAudio/AudioRingBuffer.swift`:

```swift
import Foundation
import UnisonDomain

/// Fixed-capacity FIFO of `AudioFrame`s with drop-oldest overflow.
///
/// Used by the orchestrator's outgoing pipeline to retain a short
/// (~3 s) window of mic audio that can be replayed onto a fresh WS
/// session after a brief flap. The buffer is cleared (and not
/// refilled) once the orchestrator enters `.paused` — beyond a
/// few-second outage, replaying stale audio creates more confusion
/// than it solves (see the design note in
/// `docs/superpowers/specs/2026-05-27-network-aware-session-design.md`).
///
/// Thread-safety: backed by `NSLock`. Append/drain/clear can be
/// called from any thread; one writer (the mic-frame pipeline task)
/// plus one reader (the reconnect flush) is the only pattern used in
/// practice.
public final class AudioRingBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    private let maxFrames: Int

    /// `maxFrames` is in *frame count*, not samples or seconds. With
    /// the pipeline's ~100 ms-per-frame cadence, 30 frames ≈ 3 s.
    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
        self.frames.reserveCapacity(maxFrames)
    }

    /// Append a new frame. If the buffer is full, the oldest frame
    /// is silently dropped — by the time we'd consider replaying
    /// audio that old, it's already too stale to be useful.
    public func append(_ frame: AudioFrame) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
        if frames.count > maxFrames {
            frames.removeFirst(frames.count - maxFrames)
        }
    }

    /// Return all currently-buffered frames in FIFO order and reset
    /// the buffer. Used on stream reconnect to replay the audio that
    /// was being captured while the old WS was dying.
    public func drain() -> [AudioFrame] {
        lock.lock()
        defer { lock.unlock() }
        let out = frames
        frames.removeAll(keepingCapacity: true)
        return out
    }

    /// Discard buffered frames without returning them. Called when
    /// the orchestrator enters `.paused` — audio captured during a
    /// long outage is stale, and replaying it would land the
    /// translation after the live conversation moved on.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        frames.removeAll(keepingCapacity: true)
    }
}
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter AudioRingBufferTests
```

Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonAudio/AudioRingBuffer.swift Tests/UnisonAudioTests/AudioRingBufferTests.swift
git commit -m "feat(audio): AudioRingBuffer with drop-oldest overflow for short-blip replay"
```

---

## Task 5: Per-stream `ConnectivityHealth` tracking in orchestrator

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

This task adds the *tracking* (publishing a per-stream and aggregate `ConnectivityHealth` on the orchestrator) but **not** the NWPath-driven pause yet — that's Task 6.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`:

```swift
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
```

You may need to extend `MockTranslationStream` with `func emitTranscript(_ d: TranscriptDelta)` if not already present — check existing helpers in `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift` and add if missing:

```swift
public func emitTranscript(_ d: TranscriptDelta) {
    transcriptContinuation.yield(d)
}
```

- [ ] **Step 2: Run tests — fail with missing `connectivityHealth` property**

```bash
swift test --filter orchestrator_initialHealth_isHealthy
```

- [ ] **Step 3: Add the tracking machinery to the orchestrator**

In `Sources/UnisonDomain/TranslationOrchestrator.swift`, near the existing observable state declarations:

```swift
public private(set) var connectivityHealth: ConnectivityHealth = .healthy {
    didSet {
        Self.log.info("connectivityHealth \(String(describing: oldValue)) → \(String(describing: self.connectivityHealth))")
    }
}

/// Per-stream health. UI reads the aggregate via
/// `connectivityHealth`; the diagnostic dialog reads per-speaker for
/// asymmetric-failure debugging.
private var healthBySpeaker: [Speaker: ConnectivityHealth] = [:]

/// `clock.now()` of the most recent delta (input / output / audio)
/// per speaker. The slow-detection watchdog measures from here.
private var lastDeltaAtBySpeaker: [Speaker: Date] = [:]
/// `clock.now()` of the most recent mic frame whose RMS was above the
/// audible threshold (0.001). Slow only fires when the user is
/// actually speaking — pure silence is *not* a network problem.
private var lastAudibleMicAt: Date?

/// Task driving the slow-detection scan. Restarted on every
/// session start / reconnect. Cancelled on stop.
private var slowDetectionTask: Task<Void, Never>?

private static let slowThresholdSeconds: TimeInterval = 3
private static let slowCheckIntervalSeconds: TimeInterval = 0.5
private static let micAudibleRMSThreshold: Float = 0.001
```

Update `markMicFrameReceived` (existing method) to record audible mic time:

```swift
func markMicFrameReceived(format: String = "?", sampleRate: Int = 0, rms: Float = 0) {
    if rms >= Self.micAudibleRMSThreshold {
        lastAudibleMicAt = clock.now()
    }
    // ... existing first-frame logging logic stays unchanged below ...
    guard !anyMicFrameThisSession else { return }
    anyMicFrameThisSession = true
    Self.log.info("first mic frame — format=\(format) sampleRate=\(sampleRate)Hz rms=\(String(format: "%.5f", rms))")
    if rms < 0.0005 {
        Self.log.error("first mic frame — RMS \(String(format: "%.5f", rms)) is near-silent; OpenAI VAD will not trigger. Check the input gain in System Settings → Sound, or pick a different mic in the popover.")
    }
}
```

Update `markFirstDataReceived` (existing method) to record per-speaker delta time. The current method has no `speaker` parameter — add an overload that captures it from the transcript / output pipeline callsites. Concretely, in `wireOutgoingPipeline` the consumer becomes:

```swift
let task3 = Task { @MainActor [transcript, stream, weak self] in
    for await d in stream.transcripts {
        self?.recordDeltaArrival(speaker: .me)
        self?.markFirstDataReceived()
        transcript.apply(d)
    }
}
```

And in `wireIncomingPipeline`:

```swift
let transcripts = Task { @MainActor [transcript, stream, weak self] in
    for await d in stream.transcripts {
        self?.recordDeltaArrival(speaker: .peer)
        self?.markFirstDataReceived()
        transcript.apply(d)
    }
}
```

Also record on audio deltas (incoming side):

```swift
let pump = Task {
    for await wireFrame in stream.output {
        await MainActor.run { 
            self?.recordDeltaArrival(speaker: .peer)
            self?.markFirstDataReceived() 
        }
        resampledContinuation.yield(transformer.fromWire(wireFrame, targetSampleRate: 48_000))
    }
    resampledContinuation.finish()
}
```

(Do the analogous change on the me-stream side audio consumer.)

Add the new private helpers:

```swift
private func recordDeltaArrival(speaker: Speaker) {
    lastDeltaAtBySpeaker[speaker] = clock.now()
    if healthBySpeaker[speaker] != .healthy {
        healthBySpeaker[speaker] = .healthy
        recomputeAggregateHealth()
    }
}

private func recomputeAggregateHealth() {
    let values = Array(healthBySpeaker.values)
    let aggregate: ConnectivityHealth
    switch values.count {
    case 0: aggregate = .healthy
    case 1: aggregate = .aggregate(values[0])
    default: aggregate = values.reduce(.healthy, ConnectivityHealth.aggregate)
    }
    if aggregate != connectivityHealth {
        connectivityHealth = aggregate
    }
}

/// Periodic slow-detection scan. For each speaker with an active
/// stream, if the user has been audibly speaking in the last second
/// AND no delta has arrived from that speaker's stream in
/// `slowThresholdSeconds`, mark the speaker as `.slow`. The loop
/// runs every 0.5 s — finer than the threshold so we catch the
/// transition with at most a half-second lag.
private func startSlowDetectionLoop() {
    slowDetectionTask?.cancel()
    let clock = self.clock
    slowDetectionTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
            try? await clock.sleep(for: Self.slowCheckIntervalSeconds)
            guard let self else { return }
            self.evaluateSlowDetection()
        }
    }
}

private func stopSlowDetectionLoop() {
    slowDetectionTask?.cancel()
    slowDetectionTask = nil
}

private func evaluateSlowDetection() {
    guard case .translating = state else { return }
    let now = clock.now()
    let userIsSpeaking: Bool = {
        guard let last = lastAudibleMicAt else { return false }
        return now.timeIntervalSince(last) < 1.0
    }()
    guard userIsSpeaking else { return }
    var changed = false
    for speaker in [Speaker.me, Speaker.peer] {
        // Only meaningful for streams the orchestrator actually has.
        let hasStream: Bool
        switch speaker {
        case .me: hasStream = meStream != nil
        case .peer: hasStream = peerStream != nil
        }
        guard hasStream else { continue }
        let lastDelta = lastDeltaAtBySpeaker[speaker]
        let stale = lastDelta == nil
            ? false
            : now.timeIntervalSince(lastDelta!) >= Self.slowThresholdSeconds
        let target: ConnectivityHealth = stale ? .slow : (healthBySpeaker[speaker] ?? .healthy)
        if healthBySpeaker[speaker] != target {
            healthBySpeaker[speaker] = target
            changed = true
        }
    }
    if changed { recomputeAggregateHealth() }
}
```

In `start(mode:languages:settings:)`, after the state transitions to `.translating` (just after the existing `state = .translating(...)` line), seed per-stream healths and start the loop:

```swift
healthBySpeaker = [:]
if mode == .call || mode == .test { healthBySpeaker[.me] = .healthy }
if mode == .call || mode == .listen { healthBySpeaker[.peer] = .healthy }
lastDeltaAtBySpeaker = [:]
lastAudibleMicAt = nil
connectivityHealth = .healthy
startSlowDetectionLoop()
```

In `stopAllStreams()`, before `state = .idle`:

```swift
stopSlowDetectionLoop()
healthBySpeaker = [:]
lastDeltaAtBySpeaker = [:]
lastAudibleMicAt = nil
connectivityHealth = .healthy
```

Also note: the `ManualClock` test helper needs `func advance(by:)` and a working `sleep(for:)` that wakes immediately when the simulated time passes the deadline. If `ManualClock` doesn't exist yet, add it to `Tests/UnisonDomainTests/CodableHelpers.swift` (or a new `TestClocks.swift`):

```swift
import Foundation
@testable import UnisonDomain

final class ManualClock: Clock, @unchecked Sendable {
    private var current: Date
    private let lock = NSLock()
    init(now: Date = Date(timeIntervalSince1970: 1_000_000_000)) { self.current = now }
    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
    func sleep(for seconds: TimeInterval) async throws {
        // Yield once so awaiters get a chance to observe the new
        // `now()` after the test advances time. Doesn't actually
        // wait — tests drive virtual time via `advance`.
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}
```

If `Clock` doesn't expose `sleep(for:)` yet (existing `Clock` protocol may only have `now()`), extend it minimally — keep production `SystemClock` using `Task.sleep(nanoseconds:)`. Check `Sources/UnisonDomain/Clock.swift` first; only add what's missing.

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter "orchestrator_initialHealth|orchestrator_micFramesAudible|orchestrator_deltaArrival"
```

Expected: 3 tests pass. Verify no regression in existing orchestrator tests:

```bash
swift test --filter "TranslationOrchestratorTests"
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranslationOrchestrator.swift Sources/UnisonDomain/Clock.swift Tests/UnisonDomainTests/
git commit -m "feat(orchestrator): per-stream ConnectivityHealth + slow-detection loop"
```

---

## Task 6: Wire `NetworkMonitor` into the orchestrator (pause / auto-resume)

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Modify: `Sources/UnisonApp/Composition.swift`
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
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
    // Resume goes paused(.awaitingNetwork) → connecting → translating.
    // The final state we care about is `.translating`.
    if case .translating = o.state {
        // ok
    } else {
        Issue.record("Expected .translating after network restored, got \(o.state)")
    }
}
```

You need to extend `makeOrchestrator` (the test helper at the top of `TranslationOrchestratorTests.swift`) to accept an optional `networkMonitor: any NetworkPathMonitoring = MockNetworkPathMonitor(initial: .satisfied)`. The production `TranslationOrchestrator.init` will gain the same parameter.

- [ ] **Step 2: Run — fails with no `networkMonitor` parameter**

```bash
swift test --filter "orchestrator_networkUnsatisfied|orchestrator_networkSatisfiedWhilePaused"
```

- [ ] **Step 3: Extend the orchestrator init + add pause/resume handling**

In `Sources/UnisonDomain/TranslationOrchestrator.swift`:

```swift
public init(
    micCapture: any MicrophoneCapture,
    peerCapture: any PeerAudioCapture,
    outputMixer: any AudioOutputMixer,
    virtualMicPlayer: any AudioPlayer,
    translationFactory: any TranslationStreamFactory,
    permissions: any PermissionsService,
    deviceRegistry: any AudioDeviceRegistry,
    clock: any Clock,
    transformer: any AudioFormatTransformer,
    networkMonitor: any NetworkPathMonitoring   // NEW
) {
    self.transcript = TranscriptStore()
    self.micCapture = micCapture
    // ... existing assignments ...
    self.networkMonitor = networkMonitor
}

private let networkMonitor: any NetworkPathMonitoring
private var networkObserverTask: Task<Void, Never>?
private var pauseRecoveryWatchdogTask: Task<Void, Never>?
private static let pauseRecoveryWatchdogSeconds: TimeInterval = 60
```

In `start(...)`, after `state = .translating(...)` and after `startSlowDetectionLoop()`:

```swift
startNetworkObserver(mode: mode, languages: languages)
```

Add the helper methods:

```swift
private func startNetworkObserver(mode: SessionMode, languages: LanguagePair) {
    networkObserverTask?.cancel()
    let stream = networkMonitor.statusStream
    networkObserverTask = Task { @MainActor [weak self] in
        for await status in stream {
            if Task.isCancelled { return }
            guard let self else { return }
            self.handleNetworkStatusChange(status, mode: mode, languages: languages)
        }
    }
}

private func stopNetworkObserver() {
    networkObserverTask?.cancel()
    networkObserverTask = nil
}

private func handleNetworkStatusChange(
    _ status: NetworkPathStatus,
    mode: SessionMode,
    languages: LanguagePair
) {
    switch status {
    case .unsatisfied:
        enterNetworkPause(mode: mode)
    case .satisfied:
        if case .paused(_, _, _, .networkLost) = state {
            resumeFromNetworkPause(mode: mode, languages: languages)
        }
    }
}

/// Tear down streams + captures and flip to `.paused(.networkLost)`.
/// Idempotent — calling while already paused is a no-op.
private func enterNetworkPause(mode: SessionMode) {
    if case .paused = state { return }
    guard let startedAt = sessionStartedAt else { return }
    Self.log.info("network unsatisfied — entering .paused(.networkLost)")
    stopSlowDetectionLoop()
    for (_, tasks) in pipelineTasksBySpeaker {
        for t in tasks { t.cancel() }
    }
    pipelineTasksBySpeaker.removeAll()
    micCapture.stop()
    peerCapture.stop()
    Task { @MainActor [weak self] in
        await self?.meStream?.close()
        await self?.peerStream?.close()
    }
    meStream = nil
    peerStream = nil
    state = .paused(mode: mode, since: clock.now(), startedAt: startedAt, reason: .networkLost)
    armPauseRecoveryWatchdog()
}

/// Re-establish streams. The connect path is the same as `start` —
/// we reuse it to keep one code path for "open WS + wire pipelines".
private func resumeFromNetworkPause(mode: SessionMode, languages: LanguagePair) {
    guard case .paused(_, _, let startedAt, .networkLost) = state else { return }
    Self.log.info("network satisfied during pause — resuming")
    state = .paused(mode: mode, since: clock.now(), startedAt: startedAt, reason: .awaitingNetwork)
    Task { @MainActor [weak self] in
        guard let self else { return }
        await self.resumeStreams(mode: mode, languages: languages, startedAt: startedAt)
    }
}

private func resumeStreams(
    mode: SessionMode,
    languages: LanguagePair,
    startedAt: Date
) async {
    // Open peer stream first (matches original `start` ordering).
    if mode == .call || mode == .listen {
        let peer = translationFactory.make(speaker: .peer)
        do {
            try await peer.connect(target: languages.mine)
            peerStream = peer
            wireIncomingPipeline(stream: peer)
            observeConnectionState(stream: peer, speaker: .peer, target: languages.mine, mode: mode)
        } catch {
            await failResume(error: error)
            return
        }
    }
    if mode == .call || mode == .test {
        let me = translationFactory.make(speaker: .me)
        do {
            try await me.connect(target: languages.peer)
            meStream = me
            wireOutgoingPipeline(stream: me, destination: mode == .test ? .speakers : .virtualMic)
            observeConnectionState(stream: me, speaker: .me, target: languages.peer, mode: mode)
        } catch {
            await failResume(error: error)
            return
        }
    }
    cancelPauseRecoveryWatchdog()
    state = .translating(mode: mode, startedAt: startedAt)
    healthBySpeaker = [:]
    if mode == .call || mode == .test { healthBySpeaker[.me] = .recovering }
    if mode == .call || mode == .listen { healthBySpeaker[.peer] = .recovering }
    recomputeAggregateHealth()
    startSlowDetectionLoop()
    armRecoveringFlash()
}

private func failResume(error: Error) async {
    Self.log.error("resume failed: \(String(describing: error)); falling back to terminal .error")
    await stopAllStreams()
    state = .error(.networkLost)
}

/// Force terminal `.error(.networkLost)` if pause-recovery hasn't
/// succeeded in `pauseRecoveryWatchdogSeconds` (60 s). Defense in
/// depth — without it a never-returning network leaves the app in
/// `.paused` forever.
private func armPauseRecoveryWatchdog() {
    pauseRecoveryWatchdogTask?.cancel()
    let clock = self.clock
    pauseRecoveryWatchdogTask = Task { @MainActor [weak self] in
        try? await clock.sleep(for: Self.pauseRecoveryWatchdogSeconds)
        guard let self else { return }
        if Task.isCancelled { return }
        if case .paused = self.state {
            Self.log.error("pause-recovery watchdog fired after \(Self.pauseRecoveryWatchdogSeconds)s — forcing terminal .networkLost")
            await self.stopAllStreams()
            self.state = .error(.networkLost)
        }
    }
}

private func cancelPauseRecoveryWatchdog() {
    pauseRecoveryWatchdogTask?.cancel()
    pauseRecoveryWatchdogTask = nil
}

/// Hold `.recovering` health for 2 s after resume, then drop to the
/// natural `.healthy` (or whatever the slow-detection loop computes).
private func armRecoveringFlash() {
    let clock = self.clock
    Task { @MainActor [weak self] in
        try? await clock.sleep(for: 2)
        guard let self else { return }
        for s in [Speaker.me, Speaker.peer] where self.healthBySpeaker[s] == .recovering {
            self.healthBySpeaker[s] = .healthy
        }
        self.recomputeAggregateHealth()
    }
}
```

In `stopAllStreams()`, also cancel the new tasks:

```swift
stopNetworkObserver()
cancelPauseRecoveryWatchdog()
```

In `Sources/UnisonApp/Composition.swift`, pass a real `NetworkMonitor` to the orchestrator constructor:

```swift
self.orchestrator = TranslationOrchestrator(
    micCapture: mic,
    peerCapture: peerCap,
    outputMixer: mixer,
    virtualMicPlayer: bhPlayer,
    translationFactory: factory,
    permissions: permissions,
    deviceRegistry: registry,
    clock: SystemClock(),
    transformer: ResamplerAdapter(),
    networkMonitor: NetworkMonitor()
)
```

Add `import UnisonSystem` to `Composition.swift` if not already present.

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter "orchestrator_networkUnsatisfied|orchestrator_networkSatisfiedWhilePaused"
swift test --filter TranslationOrchestratorTests
```

Expected: new tests pass + existing tests stay green.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranslationOrchestrator.swift Sources/UnisonApp/Composition.swift Tests/UnisonDomainTests/
git commit -m "feat(orchestrator): NetworkMonitor-driven .paused + auto-resume on network return"
```

---

## Task 7: Wire `AudioRingBuffer` into the outgoing pipeline

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test @MainActor func orchestrator_streamReconnect_flushesAudioBuffer() async throws {
    let mic = MockMicrophoneCapture()
    let factory = MockTranslationStreamFactory()
    let o = makeOrchestrator(mic: mic, factory: factory)
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

    // Simulate connection failure → triggers reconnect → factory
    // hands out a fresh stream. The orchestrator should drain the
    // ring buffer into the new stream BEFORE wiring live mic.
    initialStream.failConnection(.networkLost)
    try? await Task.sleep(nanoseconds: 500_000_000)

    let newStream = factory.streams[.me]!
    #expect(newStream !== initialStream)
    // The flush should have moved buffered frames (5 we just sent)
    // into the new stream's sentFrames before any new mic frame
    // arrives.
    #expect(newStream.sentFrames.count >= 5)
}
```

This test assumes `MockTranslationStream` exposes `failConnection(_:)` and `sentFrames` — extend if missing. Also assumes `factory.streams[.me]` returns the latest stream after reconnect (so check existing factory shape and adjust the test if it returns the first stream instead).

- [ ] **Step 2: Run — fails because no buffer integration yet**

```bash
swift test --filter orchestrator_streamReconnect_flushesAudioBuffer
```

- [ ] **Step 3: Wire the buffer into `wireOutgoingPipeline` + reconnect path**

Add a property on the orchestrator:

```swift
private var audioBufferBySpeaker: [Speaker: AudioRingBuffer] = [:]
/// 3 s at ~100 ms frames = 30 frames. Matches the design's
/// brief-blip recovery window.
private static let audioBufferFrames: Int = 30
```

In `wireOutgoingPipeline`, modify `task1` (the mic-frame consumer) to also write to the buffer:

```swift
let task1 = Task { [stream, weak self] in
    var frameIndex = 0
    for await frame in micFrames {
        let rms = Self.rms(frame)
        let formatLabel = String(describing: frame.format)
        let sampleRate = frame.sampleRate
        let idx = frameIndex
        await MainActor.run { [weak self] in
            self?.markMicFrameReceived(format: formatLabel, sampleRate: sampleRate, rms: rms)
            self?.logMicLevel(rms: rms, frameIndex: idx)
        }
        let wire = transformer.toWire(frame)
        await MainActor.run { [weak self] in
            self?.audioBufferBySpeaker[.me]?.append(wire)
        }
        await stream.send(wire)
        frameIndex += 1
    }
}
```

Allocate the buffer when `me` stream is created in `start(...)`:

```swift
if mode == .call || mode == .test {
    audioBufferBySpeaker[.me] = AudioRingBuffer(maxFrames: Self.audioBufferFrames)
    // ... existing me-stream connect logic ...
}
```

In the reconnect success branch of `handleStreamFailure` (the `case .me:` branch right after the new stream connects), flush the buffer to the new stream BEFORE calling `wireOutgoingPipeline`:

```swift
case .me:
    meStream = newStream
    if let buf = audioBufferBySpeaker[.me] {
        let buffered = buf.drain()
        if !buffered.isEmpty {
            Self.log.info("flushing \(buffered.count) buffered audio frames to fresh me-stream")
            Task { [newStream] in
                for f in buffered { await newStream.send(f) }
            }
        }
    }
    wireOutgoingPipeline(
        stream: newStream,
        destination: mode == .test ? .speakers : .virtualMic
    )
```

In `enterNetworkPause`, clear the buffer:

```swift
audioBufferBySpeaker.values.forEach { $0.clear() }
```

In `stopAllStreams`:

```swift
audioBufferBySpeaker.removeAll()
```

- [ ] **Step 4: Run test to confirm pass**

```bash
swift test --filter orchestrator_streamReconnect_flushesAudioBuffer
swift test --filter TranslationOrchestratorTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranslationOrchestrator.swift Tests/UnisonDomainTests/
git commit -m "feat(orchestrator): replay 3s mic-audio ring buffer on stream reconnect"
```

---

## Task 8: Track in-flight entries during pause / reconnect (TranscriptStore)

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptStore.swift`
- Test: `Tests/UnisonDomainTests/TranscriptStoreTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
@Test func transcriptStore_markEntriesAtRisk_setsFlag() {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    #expect(store.entries[0].translationAtRisk == false)
    store.markActiveEntriesAtRisk()
    #expect(store.entries[0].translationAtRisk == true)
}

@MainActor
@Test func transcriptStore_lateTranslationDelta_clearsAtRisk() {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    store.markActiveEntriesAtRisk()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hi", isFinal: false))
    #expect(store.entries[0].translationAtRisk == false)
}
```

- [ ] **Step 2: Run — fails: TranscriptEntry has no `translationAtRisk` property**

```bash
swift test --filter transcriptStore_markEntriesAtRisk_setsFlag
```

- [ ] **Step 3: Extend `TranscriptEntry` and `TranscriptStore`**

In `Sources/UnisonDomain/TranscriptEntry.swift` (check exact filename) add the field:

```swift
public struct TranscriptEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let speaker: Speaker
    public var originalText: String?
    public var translatedText: String
    public var sourceLanguage: Language?
    public var targetLanguage: Language?
    public let timestamp: Date
    /// True when the orchestrator transitioned through .paused /
    /// .reconnecting while this entry was still accumulating
    /// deltas. Used by `BubbleViewModel.translationLost` to decide
    /// whether to render the "перевод не получен" placeholder. A
    /// late-arriving translation delta clears this flag.
    public var translationAtRisk: Bool = false

    // existing init signature stays, with translationAtRisk defaulting to false
}
```

In `Sources/UnisonDomain/TranscriptStore.swift`, add:

```swift
/// Flag every currently-accumulating entry (one without a complete
/// translation) as "at risk" of translation loss. Called by the
/// orchestrator when it transitions to `.paused` / `.reconnecting`
/// so the bubble view can later render a placeholder for entries
/// that never received their translation.
public func markActiveEntriesAtRisk() {
    for idx in entries.indices where entries[idx].translatedText.isEmpty {
        entries[idx].translationAtRisk = true
    }
}
```

Update `apply(_:)` to clear the flag whenever a translation delta lands:

```swift
public func apply(_ delta: TranscriptDelta) {
    if let idx = entries.firstIndex(where: { $0.id == delta.entryId }) {
        switch delta.kind {
        case .original:
            entries[idx].originalText = (entries[idx].originalText ?? "") + delta.text
        case .translated:
            entries[idx].translatedText += delta.text
            entries[idx].translationAtRisk = false
        }
    } else {
        // ... existing new-entry creation logic ...
    }
    onDeltaApplied?(delta.entryId)
}
```

In `TranslationOrchestrator`, in `enterNetworkPause` and at the top of `handleStreamFailure`, call:

```swift
transcript.markActiveEntriesAtRisk()
```

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter transcriptStore_
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptStore.swift Sources/UnisonDomain/TranscriptEntry.swift Sources/UnisonDomain/TranslationOrchestrator.swift Tests/UnisonDomainTests/TranscriptStoreTests.swift
git commit -m "feat(transcript): mark active entries at-risk during pause/reconnect"
```

---

## Task 9: `BubbleViewModel.translationLost` + Bubble placeholder render

**Files:**
- Modify: `Sources/UnisonUI/BubbleViewModel.swift`
- Modify: `Sources/UnisonUI/TranscriptGrouping.swift` (where bubbles are built from entries)
- Modify: `Sources/UnisonUI/Components/Bubble.swift`
- Test: `Tests/UnisonDomainTests/TranscriptViewModelTests.swift` (already imports UnisonUI)

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
@Test func bubble_translationAtRiskWithEmptyTranslation_marksLost() {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Тест", isFinal: false))
    store.markActiveEntriesAtRisk()
    let vm = TranscriptViewModel(store: store)
    let groups = vm.bubbleGroups
    #expect(groups.first?.bubbles.first?.translationLost == true)
}

@MainActor
@Test func bubble_translationDelivered_clearsLost() {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Тест", isFinal: false))
    store.markActiveEntriesAtRisk()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Test", isFinal: true))
    let vm = TranscriptViewModel(store: store)
    #expect(vm.bubbleGroups.first?.bubbles.first?.translationLost == false)
}
```

- [ ] **Step 2: Run — fails (translationLost property missing)**

```bash
swift test --filter "bubble_translationAtRisk|bubble_translationDelivered"
```

- [ ] **Step 3: Add the property + derivation**

In `Sources/UnisonUI/BubbleViewModel.swift`, extend `BubbleViewModel`:

```swift
public struct BubbleViewModel: Identifiable, Equatable {
    public let id: UUID
    public let speaker: Speaker
    public let primaryText: String
    public let secondaryText: String
    public let isFirstInGroup: Bool
    public let isLastInGroup: Bool
    public let isLive: Bool
    /// True when the source-language text exists but the translation
    /// never arrived AND the orchestrator transitioned through
    /// pause/reconnect during this entry's lifetime. Drives a grey
    /// italic placeholder in `Bubble.swift` where the translation
    /// would normally render.
    public let translationLost: Bool

    public init(
        id: UUID, speaker: Speaker,
        primaryText: String, secondaryText: String,
        isFirstInGroup: Bool, isLastInGroup: Bool,
        isLive: Bool, translationLost: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.isFirstInGroup = isFirstInGroup
        self.isLastInGroup = isLastInGroup
        self.isLive = isLive
        self.translationLost = translationLost
    }
}
```

In `Sources/UnisonUI/TranscriptGrouping.swift`, update `bubbles(for entry:splitThreshold:)` to pass `translationLost` through. The derivation:

```swift
// For .me speaker: translation is the secondaryText.
// For .peer speaker: translation is the primaryText (peer's translatedText is
// rendered as primary).
//
// translationLost holds when entry.translationAtRisk == true AND
// entry.translatedText is still empty. A non-empty translation —
// even a partial one that arrived before the pause — counts as
// "we got something" and clears the lost marker.
let translationLost = entry.translationAtRisk && entry.translatedText.isEmpty
```

Pass this flag into every `BubbleViewModel(...)` the function creates, applying it ONLY to the last bubble of a multi-bubble split (the placeholder belongs at the tail of the broken phrase, not interleaved into earlier-rendered fragments):

```swift
return splitBubbles.enumerated().map { offset, parts in
    BubbleViewModel(
        id: ..., speaker: entry.speaker,
        primaryText: parts.primary,
        secondaryText: parts.secondary,
        isFirstInGroup: offset == 0,
        isLastInGroup: offset == splitBubbles.count - 1,
        isLive: ...,
        translationLost: offset == splitBubbles.count - 1 ? translationLost : false
    )
}
```

In `Sources/UnisonUI/Components/Bubble.swift`, where `secondaryText` is rendered (the translation line), render a placeholder when `translationLost == true && secondaryText.isEmpty`:

```swift
if model.translationLost && model.secondaryText.isEmpty {
    HStack(spacing: 4) {
        Image(systemName: "exclamationmark.bubble")
            .font(.system(size: 10))
        Text("Перевод не получен — нестабильная сеть")
            .font(.system(size: 13, weight: .regular).italic())
    }
    .foregroundStyle(UnisonColors.whiteAlpha(0.45))
} else if !model.secondaryText.isEmpty {
    // existing translation-text rendering
}
```

(Adjust the exact insertion point to match the file's current structure — `Bubble.swift` has separate me / peer rendering branches; the placeholder belongs in BOTH branches where `secondaryText` is normally rendered.)

- [ ] **Step 4: Run test to confirm pass**

```bash
swift test --filter "bubble_translationAtRisk|bubble_translationDelivered"
swift test --filter TranscriptViewModelTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/BubbleViewModel.swift Sources/UnisonUI/TranscriptGrouping.swift Sources/UnisonUI/Components/Bubble.swift Tests/UnisonDomainTests/TranscriptViewModelTests.swift
git commit -m "feat(ui): render 'перевод не получен' placeholder for at-risk bubbles"
```

---

## Task 10: `StatusDot` `.paused` + `.recovering` states

**Files:**
- Modify: `Sources/UnisonUI/Components/StatusDot.swift`
- Test: `Tests/UnisonUITests/__Snapshots__/StatusDotSnapshotTests/` (new snapshot tests if any exist; if not, no test required beyond compile-time)

- [ ] **Step 1: Read current `StatusDot`**

```bash
cat Sources/UnisonUI/Components/StatusDot.swift
```

Confirm the existing enum (likely `case ready, active, warn` or similar) and the colour mapping. We extend without renaming.

- [ ] **Step 2: Add two states + colours**

In `Sources/UnisonUI/Components/StatusDot.swift`, extend the `State` enum:

```swift
public enum State: Sendable, Equatable {
    case ready
    case active
    case warn
    case paused      // NEW — grey, for .paused(.networkLost)
    case recovering  // NEW — cyan with brief opacity pulse
}
```

And the colour helper:

```swift
private var fill: Color {
    switch state {
    case .ready: UnisonColors.whiteAlpha(0.40)
    case .active: UnisonColors.active        // existing cyan
    case .warn: UnisonColors.warn            // existing yellow
    case .paused: UnisonColors.whiteAlpha(0.30)
    case .recovering: UnisonColors.active
    }
}
```

For `.recovering`, add a 2-cycle opacity pulse via `.modifier(...)` or a `withAnimation` on a stateful `pulsing: Bool` that toggles every 600 ms. Implementation hint: use `TimelineView(.animation)` already imported in the file or `@State` + `.onAppear { withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) { ... } }`. Specific code:

```swift
@SwiftUI.State private var recoveringPulse = false

public var body: some View {
    Circle()
        .fill(fill)
        .opacity(state == .recovering ? (recoveringPulse ? 0.55 : 1.0) : 1.0)
        .frame(width: size, height: size)
        .onChange(of: state) { _, newState in
            if newState == .recovering {
                withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) {
                    recoveringPulse = true
                }
            } else {
                recoveringPulse = false
            }
        }
}
```

- [ ] **Step 3: Build to verify it compiles**

```bash
swift build
```

Expected: clean build, no compile errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/UnisonUI/Components/StatusDot.swift
git commit -m "feat(ui): add StatusDot.paused (grey) + .recovering (pulsing cyan)"
```

---

## Task 11: `PopoverViewModel` status text + dot mapping

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/PopoverViewModel.swift`
- Modify: `Sources/UnisonUI/Views/PopoverView.swift` (to read new state)
- Test: `Tests/UnisonDomainTests/PopoverViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test func popoverVM_pausedNetworkLost_statusText() {
    let started = Date()
    let vm = makeReadyVM()
    // Force-override state via the orchestrator stub used in
    // makeReadyVM; if the test infrastructure uses
    // PopoverViewModel.previewing, use that constructor instead.
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .paused(mode: .call, since: Date(), startedAt: started, reason: .networkLost),
        permissions: PreviewPermissions(),
        deviceRegistry: PreviewDeviceRegistry()
    )
    #expect(preview.statusText == "Нет интернета. Ждём…")
    #expect(preview.statusDotState == .paused)
}

@MainActor
@Test func popoverVM_translatingSlow_statusText() {
    let started = Date()
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .translating(mode: .call, startedAt: started),
        permissions: PreviewPermissions(),
        deviceRegistry: PreviewDeviceRegistry(),
        connectivityHealth: .slow
    )
    #expect(preview.statusText == "Медленная сеть")
    #expect(preview.statusDotState == .warn)
}

@MainActor
@Test func popoverVM_translatingHealthy_statusText_empty() {
    let started = Date()
    let preview = PopoverViewModel.previewing(
        settings: .default,
        state: .translating(mode: .call, startedAt: started),
        permissions: PreviewPermissions(),
        deviceRegistry: PreviewDeviceRegistry(),
        connectivityHealth: .healthy
    )
    #expect(preview.statusText == "")   // empty → no secondary line shown
    #expect(preview.statusDotState == .active)
}
```

You'll need to extend `PopoverViewModel.previewing(...)` to accept a `connectivityHealth: ConnectivityHealth = .healthy` parameter. If the existing previewing signature doesn't have it, add it as an optional kwarg.

- [ ] **Step 2: Run — fails (statusText / statusDotState / health param missing)**

```bash
swift test --filter "popoverVM_pausedNetworkLost|popoverVM_translatingSlow|popoverVM_translatingHealthy"
```

- [ ] **Step 3: Add the computed properties + plumbing**

In `Sources/UnisonUI/ViewModels/PopoverViewModel.swift`:

```swift
/// Aggregate connectivity health, read from the orchestrator when
/// available, falls back to the preview override otherwise.
public var connectivityHealth: ConnectivityHealth {
    orchestrator?.connectivityHealth ?? previewConnectivityHealth
}
/// `internal` (not `private`) so snapshot tests reaching in via
/// `@testable import UnisonUI` can prime a state without driving the
/// real orchestrator.
var previewConnectivityHealth: ConnectivityHealth = .healthy

/// Human-readable status line shown below the timer / primary
/// button. Empty string means "no secondary line at all".
public var statusText: String {
    switch state {
    case .idle, .connecting, .error:
        return ""
    case .reconnecting:
        return "Переподключение…"
    case .paused(_, _, _, .networkLost):
        return "Нет интернета. Ждём…"
    case .paused(_, _, _, .awaitingNetwork):
        return "Возобновляем…"
    case .translating:
        switch connectivityHealth {
        case .slow: return "Медленная сеть"
        case .recovering: return "Связь восстановлена"
        case .healthy: return ""
        }
    }
}

/// `StatusDot.State` derived from `state` × `connectivityHealth`.
/// Mirrors the table in the spec.
public var statusDotState: StatusDot.State {
    switch state {
    case .idle: return .ready
    case .connecting: return .active
    case .reconnecting: return .warn
    case .paused: return .paused
    case .error: return .warn  // error already speaks for itself; keep dot present
    case .translating:
        switch connectivityHealth {
        case .slow: return .warn
        case .recovering: return .recovering
        case .healthy: return .active
        }
    }
}
```

Extend `PopoverViewModel.previewing(...)`:

```swift
public static func previewing(
    settings: Settings = .default,
    state: SessionState = .idle,
    permissions: any PermissionsService,
    deviceRegistry: any AudioDeviceRegistry,
    connectivityHealth: ConnectivityHealth = .healthy
) -> PopoverViewModel {
    let vm = PopoverViewModel(
        orchestrator: nil,
        permissions: permissions,
        deviceRegistry: deviceRegistry,
        settings: settings
    )
    vm.previewState = state
    vm.previewConnectivityHealth = connectivityHealth
    return vm
}
```

In `Sources/UnisonUI/Views/PopoverView.swift`, wherever the current status text is rendered, replace the hard-coded `"Переподключение…"` (in `reconnectingHint`) with reading `vm.statusText`. Wrap in `if !vm.statusText.isEmpty` so the row collapses when no secondary line applies.

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter "popoverVM_pausedNetworkLost|popoverVM_translatingSlow|popoverVM_translatingHealthy"
swift test --filter PopoverViewModelTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/ViewModels/PopoverViewModel.swift Sources/UnisonUI/Views/PopoverView.swift Tests/UnisonDomainTests/PopoverViewModelTests.swift
git commit -m "feat(ui): popover status text + dot state for .paused / .slow / .recovering"
```

---

## Task 12: `TranscriptViewModel` status text for control pill

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift`
- Modify: `Sources/UnisonUI/Components/ControlPill.swift`
- Modify: `Sources/UnisonUI/Views/TranscriptView.swift`
- Test: `Tests/UnisonDomainTests/TranscriptViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Test func transcriptVM_pauseNetworkLost_pillStatus() {
    let orch = makeOrchestrator()  // existing test helper
    let vm = TranscriptViewModel(store: orch.transcript, orchestrator: orch)
    let started = Date()
    // Drive orchestrator into paused via its public state (or a test
    // helper if private). One option: extend ManualOrchestrator
    // mock if such a thing exists. Otherwise inject `previewState`
    // similar to PopoverViewModel.
    // For brevity here we use `previewState`:
    vm.previewState = .paused(mode: .call, since: Date(), startedAt: started, reason: .networkLost)
    #expect(vm.pillStatusText == "Пауза")
    #expect(vm.pillDotState == .paused)
}

@MainActor
@Test func transcriptVM_translatingHealthy_pillStatus_empty() {
    let orch = makeOrchestrator()
    let vm = TranscriptViewModel(store: orch.transcript, orchestrator: orch)
    let started = Date()
    vm.previewState = .translating(mode: .call, startedAt: started)
    vm.previewConnectivityHealth = .healthy
    #expect(vm.pillStatusText == "")
    #expect(vm.pillDotState == .active)
}
```

- [ ] **Step 2: Run — fails (missing properties)**

```bash
swift test --filter "transcriptVM_pauseNetworkLost|transcriptVM_translatingHealthy"
```

- [ ] **Step 3: Add the properties**

In `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift`:

```swift
public var previewState: SessionState?
public var previewConnectivityHealth: ConnectivityHealth = .healthy

public var effectiveState: SessionState {
    previewState ?? orchestrator?.state ?? .idle
}

public var pillStatusText: String {
    switch effectiveState {
    case .reconnecting: return "Переподключение…"
    case .paused(_, _, _, .networkLost): return "Пауза"
    case .paused(_, _, _, .awaitingNetwork): return "Возобновляем…"
    case .translating:
        switch connectivityHealth {
        case .slow: return "Медленная сеть"
        case .recovering: return ""  // pill stays clean during 2s flash
        case .healthy: return ""
        }
    case .idle, .connecting, .error:
        return ""
    }
}

public var pillDotState: StatusDot.State {
    switch effectiveState {
    case .idle: return .ready
    case .connecting: return .active
    case .reconnecting: return .warn
    case .paused: return .paused
    case .error: return .warn
    case .translating:
        switch connectivityHealth {
        case .slow: return .warn
        case .recovering: return .recovering
        case .healthy: return .active
        }
    }
}

public var connectivityHealth: ConnectivityHealth {
    orchestrator?.connectivityHealth ?? previewConnectivityHealth
}
```

In `Sources/UnisonUI/Components/ControlPill.swift`, the pill already shows a `StatusDot`. Pass the new state and (optional) status text:

```swift
public init(
    isActive: Bool,
    startedAt: Date?,
    previewElapsed: TimeInterval? = nil,
    isHidden: Bool,
    isSettingsOpen: Bool,
    isTestMode: Bool = false,
    dotState: StatusDot.State = .active,
    statusText: String = "",
    onToggleSettings: @escaping () -> Void,
    onToggleHidden: @escaping () -> Void,
    onStop: @escaping () -> Void
)
```

In the `body`, replace the hard-coded `dotState` computation with the new parameter, and render `statusText` as a small label next to the timer when non-empty (subtle, secondary colour, small font).

In `Sources/UnisonUI/Views/TranscriptView.swift`, update the `controlPill` call to pass `dotState: vm.pillDotState, statusText: vm.pillStatusText`.

- [ ] **Step 4: Run tests to confirm pass**

```bash
swift test --filter "transcriptVM_pauseNetworkLost|transcriptVM_translatingHealthy"
swift test --filter TranscriptViewModelTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/ViewModels/TranscriptViewModel.swift Sources/UnisonUI/Components/ControlPill.swift Sources/UnisonUI/Views/TranscriptView.swift Tests/UnisonDomainTests/TranscriptViewModelTests.swift
git commit -m "feat(ui): control pill status text + dot state for paused / slow / recovering"
```

---

## Task 13: Snapshot tests for new popover + transcript states

**Files:**
- Modify: `Tests/UnisonUITests/PopoverViewSnapshotTests.swift`
- Modify: `Tests/UnisonUITests/TranscriptViewSnapshotTests.swift`
- New baselines in `Tests/UnisonUITests/__Snapshots__/...`

- [ ] **Step 1: Add new snapshot tests in `PopoverViewSnapshotTests`**

```swift
@Test func popover_translatingSlow() throws {
    let started = Date().addingTimeInterval(-14)
    let vm = makeVM(state: .translating(mode: .call, startedAt: started))
    vm.previewConnectivityHealth = .slow
    snap(darkFloor(PopoverView(vm: vm), size: SnapSize.popover), size: SnapSize.popover)
}

@Test func popover_pausedNetworkLost() throws {
    let started = Date().addingTimeInterval(-14)
    let size = CGSize(width: SnapSize.popover.width, height: 480)
    let vm = makeVM(state: .paused(mode: .call, since: Date(), startedAt: started, reason: .networkLost))
    snap(darkFloor(PopoverView(vm: vm), size: size), size: size)
}

@Test func popover_pausedAwaitingNetwork() throws {
    let started = Date().addingTimeInterval(-14)
    let size = CGSize(width: SnapSize.popover.width, height: 480)
    let vm = makeVM(state: .paused(mode: .call, since: Date(), startedAt: started, reason: .awaitingNetwork))
    snap(darkFloor(PopoverView(vm: vm), size: size), size: size)
}
```

Extend the existing `makeVM` helper in `PopoverViewSnapshotTests` to set `previewConnectivityHealth` if passed.

- [ ] **Step 2: Add transcript snapshot tests in `TranscriptViewSnapshotTests`**

```swift
@Test func transcript_bubbleWithLostTranslation() throws {
    let store = TranscriptStore()
    let id = UUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет, как дела?", isFinal: false))
    store.markActiveEntriesAtRisk()
    let vm = TranscriptViewModel(store: store)
    // ... render the transcript view, snap it
    snap(...)
}
```

(Match the existing transcript snapshot test pattern in `TranscriptViewSnapshotTests.swift` for the exact wrapping / sizing.)

- [ ] **Step 3: Record baselines**

```bash
RECORD_SNAPSHOTS=1 swift test --filter "PopoverViewSnapshotTests|TranscriptViewSnapshotTests"
```

Visually inspect the resulting PNG files in `__Snapshots__/...` to confirm:
- popover_translatingSlow: yellow dot, "Медленная сеть" label
- popover_pausedNetworkLost: grey dot, "Нет интернета. Ждём…"
- popover_pausedAwaitingNetwork: cyan dot, "Возобновляем…"
- transcript_bubbleWithLostTranslation: bubble with italic placeholder + exclamation icon

If any baseline looks wrong, fix the rendering code (Task 11/12 outputs), re-record.

- [ ] **Step 4: Run snapshot tests in compare mode to confirm pass**

```bash
swift test --filter "PopoverViewSnapshotTests|TranscriptViewSnapshotTests"
```

- [ ] **Step 5: Commit**

```bash
git add Tests/UnisonUITests/ 
git commit -m "test(ui): snapshot baselines for paused/slow/recovering + lost-translation bubble"
```

---

## Task 14: `DiagnosticCollector` per-stream health

**Files:**
- Modify: `Sources/UnisonApp/DiagnosticCollector.swift`
- Modify: `Sources/UnisonUI/DiagnosticInfo.swift`
- Modify: `Sources/UnisonUI/Views/DiagnosticSheet.swift` (render the new rows)

- [ ] **Step 1: Extend `DiagnosticInfo` with the new fields**

In `Sources/UnisonUI/DiagnosticInfo.swift`:

```swift
public struct DiagnosticInfo: Sendable, Equatable {
    public let appVersion: String
    public let macOSVersion: String
    // ... existing fields ...
    public let connectivityHealth: ConnectivityHealth
    public let meStreamHealth: ConnectivityHealth?    // nil when no me-stream (e.g. .listen mode)
    public let peerStreamHealth: ConnectivityHealth?  // nil when no peer-stream (e.g. .test mode)
    // ... rest of fields including collectedAt ...
}
```

- [ ] **Step 2: Surface per-stream health on the orchestrator**

In `Sources/UnisonDomain/TranslationOrchestrator.swift`:

```swift
public func streamHealth(for speaker: Speaker) -> ConnectivityHealth? {
    healthBySpeaker[speaker]
}
```

- [ ] **Step 3: Populate the fields in `DiagnosticCollector.collect()`**

```swift
return DiagnosticInfo(
    // ... existing fields ...
    connectivityHealth: composition.orchestrator.connectivityHealth,
    meStreamHealth: composition.orchestrator.streamHealth(for: .me),
    peerStreamHealth: composition.orchestrator.streamHealth(for: .peer),
    // ... rest ...
)
```

- [ ] **Step 4: Render the rows in `DiagnosticSheet`**

Add two rows under the existing audio-device rows:

```swift
DiagRow(label: "Связь me-stream", value: info.meStreamHealth.map(humanReadable) ?? "—")
DiagRow(label: "Связь peer-stream", value: info.peerStreamHealth.map(humanReadable) ?? "—")
```

Where `humanReadable(_:)` is:

```swift
private func humanReadable(_ h: ConnectivityHealth) -> String {
    switch h {
    case .healthy: return "норма"
    case .slow: return "медленно"
    case .recovering: return "восстановление"
    }
}
```

- [ ] **Step 5: Build to verify it compiles**

```bash
swift build
```

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonUI/DiagnosticInfo.swift Sources/UnisonUI/Views/DiagnosticSheet.swift Sources/UnisonApp/DiagnosticCollector.swift Sources/UnisonDomain/TranslationOrchestrator.swift
git commit -m "feat(diagnostics): surface per-stream ConnectivityHealth in DiagnosticSheet"
```

---

## Task 15: Watchdog re-tuning (sanity check + tests)

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Test: `Tests/UnisonDomainTests/TranslationOrchestratorTests.swift`

By Task 6 the new 60 s `pauseRecoveryWatchdogSeconds` is already wired in. This task adds an explicit regression test that codifies the watchdog so a future refactor doesn't accidentally cut the budget back to 15 s.

- [ ] **Step 1: Write the test**

```swift
@Test @MainActor func orchestrator_pauseRecoveryWatchdog_firesAfter60s() async throws {
    let netMon = MockNetworkPathMonitor(initial: .satisfied)
    let clock = ManualClock()
    let o = makeOrchestrator(networkMonitor: netMon, clock: clock)
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
```

- [ ] **Step 2: Run the test — confirm it passes**

```bash
swift test --filter orchestrator_pauseRecoveryWatchdog_firesAfter60s
```

If it fails, double-check Task 6's `armPauseRecoveryWatchdog` implementation actually uses `clock.sleep(for:)` (it must, so the test's `ManualClock.advance` can move past it).

- [ ] **Step 3: Commit**

```bash
git add Tests/UnisonDomainTests/TranslationOrchestratorTests.swift
git commit -m "test(orchestrator): regression test for 60s pause-recovery watchdog"
```

---

## Final integration check

- [ ] **Run the full test suite**

```bash
swift test 2>&1 | tail -5
```

Expected: all tests pass (the count should be 303 + new tests from Tasks 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 15 — roughly 20 new tests).

- [ ] **Build the app bundle**

```bash
bash scripts/bundle_app.sh
```

Expected: clean release build, `build/Unison.app` ready.

- [ ] **Manual smoke test (one full flow)**

1. Launch app (`open build/Unison.app`).
2. Open popover, press Start in `.test` mode.
3. Disable WiFi.
4. Within ~1–2 s, popover should show grey dot + "Нет интернета. Ждём…".
5. Re-enable WiFi.
6. Within a few seconds, status should flip to cyan dot + "Связь восстановлена" briefly, then disappear (back to clean timer).
7. Quit cleanly via the menubar context menu — no leftover marker.

- [ ] **Final commit (if any cleanup needed)**

```bash
git status
# If there are uncommitted whitespace-only changes from snapshot regeneration:
git add -A && git commit -m "chore: regenerate snapshot baselines after final review"
```
