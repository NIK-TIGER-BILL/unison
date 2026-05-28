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
///
/// **Multi-subscriber design.** `statusStream` is a *computed* property
/// — each access constructs a fresh `AsyncStream` and registers a new
/// continuation. The first yield is the latest cached status so a
/// subscriber that attaches mid-session immediately learns the current
/// state instead of waiting for the next transition. This matches the
/// pattern documented in `NetworkPathMonitoring` and is required by
/// the orchestrator's per-session lifecycle: every `start()` subscribes
/// freshly, and a long-lived singleton-style stream would be
/// permanently consumed after the first session ends (review
/// finding #4).
public final class NetworkMonitor: NetworkPathMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.unison.NetworkMonitor", qos: .utility)
    /// Lock guarding `_currentStatus` and `subscribers`. Both are
    /// touched from the monitor's queue (path updates) and from
    /// arbitrary actors (statusStream / currentStatus readers), so
    /// we serialise to avoid the data race the previous version
    /// silently shipped (`@unchecked Sendable` + no synchronisation).
    private let lock = NSLock()
    private var _currentStatus: NetworkPathStatus
    /// Active subscriber continuations. Yielded into on every path
    /// update; removed on stream termination.
    private var subscribers: [UUID: AsyncStream<NetworkPathStatus>.Continuation] = [:]
    /// Flips true on the first real `pathUpdateHandler` invocation.
    /// Subscribers that attach before this don't get an initial yield
    /// (we'd be lying — the seeded `.unsatisfied` is a placeholder,
    /// not an observation). Once the real status is known, subscribers
    /// attaching after that get the cached value as their first yield
    /// per the documented protocol contract (iter-2 review finding:
    /// pre-first-update subscribers would otherwise see a fabricated
    /// `.unsatisfied` and trigger a spurious pause on healthy launch).
    private var didReceiveFirstUpdate = false

    public var currentStatus: NetworkPathStatus {
        lock.lock()
        defer { lock.unlock() }
        return _currentStatus
    }

    /// Construct a fresh stream per access. Each subscriber gets:
    /// 1. The latest cached status as the first yield (so they
    ///    don't have to call `currentStatus` separately).
    /// 2. Every subsequent transition until the consumer drops the
    ///    iterator.
    ///
    /// Returning a fresh stream per call is what makes the orchestrator
    /// safe against the "session N+1 subscribes to a stream session N
    /// already consumed" failure mode (the previous version stored a
    /// single `let statusStream` instance, which AsyncStream allows to
    /// be iterated only once).
    public var statusStream: AsyncStream<NetworkPathStatus> {
        AsyncStream { continuation in
            let id = UUID()
            self.lock.lock()
            self.subscribers[id] = continuation
            // Only yield the initial value if we've actually observed
            // the network — otherwise the subscriber would receive
            // the constructor seed (a guess) and act on it before
            // the real path update fires (often within 50 ms).
            // Subscribers attaching after the first real update do
            // get the cached value as their first yield, fulfilling
            // the protocol contract.
            let initial: NetworkPathStatus? = self.didReceiveFirstUpdate ? self._currentStatus : nil
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

    public init() {
        // Seed with `.unsatisfied` on launch so synchronous callers
        // that read `currentStatus` before the monitor's first
        // pathUpdateHandler fires don't see a fabricated `.satisfied`.
        // The handler fires within milliseconds of `start(queue:)` and
        // overwrites this with the real value (review finding #11).
        self._currentStatus = .unsatisfied

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            // Treat both `.satisfied` AND `.requiresConnection` as
            // usable — the latter is a transient state during VPN /
            // cellular setup and does NOT mean "no network". The
            // previous binary mapping false-tripped on every VPN
            // handshake (review finding #12). NWPath.Status's three
            // values are matched explicitly; future Apple additions
            // hit the default branch and are conservatively treated
            // as offline.
            let translated: NetworkPathStatus
            switch path.status {
            case .satisfied: translated = .satisfied
            case .requiresConnection: translated = .satisfied
            case .unsatisfied: translated = .unsatisfied
            @unknown default: translated = .unsatisfied
            }

            self.lock.lock()
            let previous = self._currentStatus
            let isFirst = !self.didReceiveFirstUpdate
            self._currentStatus = translated
            self.didReceiveFirstUpdate = true
            // Snapshot the continuations under the lock then yield
            // OUTSIDE — yielding can synchronously invoke consumer
            // code, which must not re-enter the lock.
            let conts = Array(self.subscribers.values)
            self.lock.unlock()

            // First real update always yields (subscribers attached
            // before now didn't get an initial value — see
            // `statusStream`). After that, de-dup: only push a yield
            // when the status actually changed.
            if isFirst || previous != translated {
                for c in conts { c.yield(translated) }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
        lock.lock()
        let conts = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()
        for c in conts { c.finish() }
    }
}
