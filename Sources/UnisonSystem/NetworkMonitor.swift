import Foundation
import Network
import UnisonDomain

/// Production implementation backed by `Network.framework`'s
/// `NWPathMonitor`. Single instance per process — `NWPathMonitor`
/// itself is the system-wide path watcher; spinning up multiple is
/// wasteful but not harmful.
///
/// The `NetworkPathMonitoring` protocol and the test mock live in
/// `UnisonDomain` so the orchestrator can subscribe without an
/// `import UnisonSystem`. This file keeps only the system-backed
/// adapter, which legitimately needs `Network.framework`.
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
