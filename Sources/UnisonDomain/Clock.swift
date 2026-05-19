import Foundation

public protocol Clock: Sendable {
    func now() -> Date
    func sleep(for seconds: TimeInterval) async throws
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
