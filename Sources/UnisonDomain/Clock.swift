import Foundation

public protocol Clock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        // Clamp: `UInt64(negative or NaN)` traps at runtime. No current
        // caller passes either, but a crash is the wrong failure mode
        // for a sleep helper.
        let ns = seconds * 1_000_000_000
        guard ns.isFinite, ns > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(ns))
    }
}
