import Testing
@testable import UnisonTranslation

@Test func backoff_exponentialDoubling() {
    var p = BackoffPolicy(initial: 1, cap: 30)
    #expect(p.nextDelay() == 1)
    #expect(p.nextDelay() == 2)
    #expect(p.nextDelay() == 4)
    #expect(p.nextDelay() == 8)
    #expect(p.nextDelay() == 16)
}

@Test func backoff_capsAtMax() {
    var p = BackoffPolicy(initial: 1, cap: 10)
    _ = p.nextDelay()
    _ = p.nextDelay()
    _ = p.nextDelay()
    _ = p.nextDelay()
    #expect(p.nextDelay() == 10)
    #expect(p.nextDelay() == 10)
}

@Test func backoff_resetGoesBackToInitial() {
    var p = BackoffPolicy(initial: 1, cap: 30)
    _ = p.nextDelay(); _ = p.nextDelay(); _ = p.nextDelay()
    p.reset()
    #expect(p.nextDelay() == 1)
}
