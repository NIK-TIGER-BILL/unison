import Foundation
@testable import UnisonDomain

public final class FakeClock: Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var pending: [(deadline: Date, continuation: CheckedContinuation<Void, Error>)] = []

    public init(now: Date) { self.current = now }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func sleep(for seconds: TimeInterval) async throws {
        let deadline = now().addingTimeInterval(seconds)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            lock.lock()
            pending.append((deadline, c))
            lock.unlock()
        }
    }

    public func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let due = pending.filter { $0.deadline <= current }
        pending.removeAll { $0.deadline <= current }
        lock.unlock()
        for d in due { d.continuation.resume() }
    }

    /// Jump to an absolute instant. Resumes any sleeps now due (only when
    /// moving forward), mirroring `advance(by:)`.
    public func set(_ date: Date) {
        lock.lock()
        let forward = date > current
        current = date
        let due = forward ? pending.filter { $0.deadline <= current } : []
        if forward { pending.removeAll { $0.deadline <= current } }
        lock.unlock()
        for d in due { d.continuation.resume() }
    }
}
