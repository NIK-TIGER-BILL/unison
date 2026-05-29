import Foundation

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
/// system monitor (which has no public test seam). Lives in
/// `UnisonDomain` (not `UnisonSystem`) so the orchestrator —
/// itself a leaf-level domain type — can depend on the protocol
/// without dragging in `Network.framework`.
public protocol NetworkPathMonitoring: AnyObject, Sendable {
    /// Latest observed status. Reflects the last value emitted on
    /// `statusStream`.
    var currentStatus: NetworkPathStatus { get }
    /// Hot stream of status transitions. The first yield is the
    /// current status so subscribers don't have to call
    /// `currentStatus` separately on attach.
    var statusStream: AsyncStream<NetworkPathStatus> { get }
}

/// Test-only mock. Hold a reference, call `simulate(_:)` to push a
/// new status onto the stream and update `currentStatus`. Lives
/// alongside the protocol so unit tests in `UnisonDomain` can drive
/// orchestrator pause/resume transitions without importing
/// `UnisonSystem`.
///
/// **Multi-subscriber semantics.** Each `statusStream` access returns
/// a fresh stream, mirroring the real `NetworkMonitor`. This is what
/// makes orchestrator stop/start cycles testable — the second
/// session subscribes again and gets the current status as its first
/// yield instead of an already-consumed iterator.
///
/// **Initial-value semantics.** `init(initial:)` seeds the cached
/// status. Tests that want orchestrator subscribers to immediately
/// see that seed (the common case) construct the mock and start the
/// session — the `statusStream` getter yields the cached value as
/// the first iteration. Tests that want to mirror the production
/// "no initial yield until a real observation" semantic pass
/// `yieldInitial: false`; subscribers then only get yields from
/// subsequent `simulate(_:)` calls.
public final class MockNetworkPathMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _currentStatus: NetworkPathStatus
    private var subscribers: [UUID: AsyncStream<NetworkPathStatus>.Continuation] = [:]
    private var yieldInitial: Bool
    /// Flips true on the first `simulate(_:)`. Used to force a yield
    /// on the first update even if its status matches the seed —
    /// mirrors production NetworkMonitor's `didReceiveFirstUpdate`
    /// flag (iter-4 review finding: without this, a test driving the
    /// initial-offline-network case would silently miss a yield).
    private var didReceiveFirstSimulate: Bool = false

    public var currentStatus: NetworkPathStatus {
        lock.lock()
        defer { lock.unlock() }
        return _currentStatus
    }

    public var statusStream: AsyncStream<NetworkPathStatus> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            self.subscribers[id] = continuation
            let initial: NetworkPathStatus? = self.yieldInitial ? self._currentStatus : nil
            self.lock.unlock()
            if let initial { continuation.yield(initial) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[id] = nil
                self.lock.unlock()
            }
        }
    }

    public init(initial: NetworkPathStatus, yieldInitial: Bool = true) {
        self._currentStatus = initial
        self.yieldInitial = yieldInitial
    }

    public func simulate(_ status: NetworkPathStatus) {
        lock.lock()
        let previous = _currentStatus
        // `isFirst` tracks the FIRST `simulate(_:)` call exactly the
        // way production's `NetworkMonitor` tracks `didReceiveFirstUpdate`
        // (NetworkMonitor.swift first-update branch). The first
        // simulate must always yield even if its status matches the
        // seed — otherwise a test that constructs
        // `init(initial: .unsatisfied, yieldInitial: false)` and then
        // simulates `.unsatisfied` (genuinely-offline launch) would
        // see no yield, whereas production would yield (iter-4
        // review finding).
        let isFirst = !didReceiveFirstSimulate
        _currentStatus = status
        didReceiveFirstSimulate = true
        // After the first simulate, subscribers attaching later
        // should see the new value as their initial yield — mirror
        // the production `didReceiveFirstUpdate` semantic.
        self.yieldInitial = true
        let conts = Array(subscribers.values)
        lock.unlock()
        // First update always yields. Subsequent updates de-dup on
        // equality so a regression test driving two consecutive
        // identical statuses sees one yield (mirror production).
        if !isFirst, previous == status { return }
        for c in conts { c.yield(status) }
    }

    public func finish() {
        lock.lock()
        let conts = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }
}
