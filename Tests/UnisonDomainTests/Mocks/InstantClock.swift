import Foundation
@testable import UnisonDomain

/// `Clock` that returns immediately from `sleep(for:)` while still
/// advancing its virtual `now()`. Useful for tests that need to drive
/// the orchestrator's reconnect retry-loop to completion (the
/// FakeClock approach requires manual `advance(by:)` calls that race
/// against actor hops in the failure handler).
///
/// All access is through `@MainActor` because the orchestrator runs
/// on the main actor and tests using this clock also run on the main
/// actor (so no synchronisation is needed).
@MainActor
public final class InstantClock: Clock {
    private var current: Date
    private nonisolated(unsafe) var snapshot: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        self.current = now
        self.snapshot = now
    }

    public nonisolated func now() -> Date { snapshot }

    public nonisolated func sleep(for seconds: TimeInterval) async throws {
        // The orchestrator awaits this from the main actor — hop
        // there to read/write the virtual clock safely.
        await MainActor.run {
            self.current = self.current.addingTimeInterval(seconds)
            self.snapshot = self.current
        }
        await Task.yield()
    }
}
