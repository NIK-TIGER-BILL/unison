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
