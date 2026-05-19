import Foundation

public struct CostEstimator: Sendable {
    public struct Pricing: Sendable {
        public let perMinutePerStream: Double

        public static let `default` = Pricing(perMinutePerStream: 0.03)
    }

    public let pricing: Pricing

    public init(pricing: Pricing) {
        self.pricing = pricing
    }

    public func estimatedCost(mode: SessionMode, durationSeconds: TimeInterval) -> Double {
        let streams: Double = mode == .call ? 2 : 1
        let minutes = durationSeconds / 60.0
        return streams * minutes * pricing.perMinutePerStream
    }
}
