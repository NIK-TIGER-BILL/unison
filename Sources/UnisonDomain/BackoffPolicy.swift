import Foundation

public struct BackoffPolicy: Sendable {
    public let initial: TimeInterval
    public let cap: TimeInterval
    private var attempt: Int = 0

    public init(initial: TimeInterval = 1, cap: TimeInterval = 30) {
        self.initial = initial
        self.cap = cap
    }

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(initial * pow(2.0, Double(attempt)), cap)
        attempt += 1
        return delay
    }

    public mutating func reset() {
        attempt = 0
    }
}
