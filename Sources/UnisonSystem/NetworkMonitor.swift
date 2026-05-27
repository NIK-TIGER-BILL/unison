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
