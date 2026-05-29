import Foundation
@testable import UnisonDomain

/// Test clock that advances `now()` only via explicit `advance(by:)`
/// calls. `sleep(for:)` suspends until `advance` crosses the deadline.
///
/// Long-running watchdogs (no-data 20s, reconnect 15s) sleep here and
/// won't fire unless an explicit `advance` crosses their deadline —
/// so a short test that advances the clock just past the 3 s slow
/// threshold can drive the slow-detection loop without accidentally
/// tripping any other deadline-based watchdog.
final class ManualClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var pending: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(now: Date = Date(timeIntervalSince1970: 1_000_000_000)) {
        self.current = now
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    /// Move virtual time forward by `seconds`. Any pending `sleep`
    /// whose deadline now falls at or before the new `current` is
    /// resumed. Continuations re-arm with new deadlines past the new
    /// `current`, so a single `advance` releases exactly one round of
    /// deadlines — periodic loops iterate once per `advance`.
    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = pending.filter { $0.deadline <= current }
        pending.removeAll { $0.deadline <= current }
        lock.unlock()
        for d in due { d.continuation.resume() }
    }

    func sleep(for seconds: TimeInterval) async throws {
        let deadline = now().addingTimeInterval(seconds)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            pending.append((deadline, c))
            lock.unlock()
        }
    }
}
