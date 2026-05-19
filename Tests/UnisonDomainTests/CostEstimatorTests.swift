import Testing
@testable import UnisonDomain

@Test func cost_callModeUsesBothDirections() {
    let est = CostEstimator(pricing: .default)
    let cost = est.estimatedCost(mode: .call, durationSeconds: 60)
    #expect(cost > 0)
}

@Test func cost_listenModeIsHalfOfCall() {
    let est = CostEstimator(pricing: .default)
    let call = est.estimatedCost(mode: .call, durationSeconds: 120)
    let listen = est.estimatedCost(mode: .listen, durationSeconds: 120)
    #expect(abs(listen - call / 2) < 0.0001)
}

@Test func cost_zeroDurationIsZero() {
    let est = CostEstimator(pricing: .default)
    #expect(est.estimatedCost(mode: .call, durationSeconds: 0) == 0)
}
