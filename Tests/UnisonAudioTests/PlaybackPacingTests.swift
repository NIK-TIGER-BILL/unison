import Foundation
import Testing
@testable import UnisonAudio

@Test func pacing_noQueue_targetIsOne() {
    let r = PlaybackPacing.computeRate(depth: 0.0, velocity: 0.0)
    #expect(r.target == 1.0)
    #expect(r.p == 0.0)
    #expect(r.d == 0.0)
}

@Test func pacing_atTarget_targetIsOne() {
    // At exactly the target queue depth, P=0 (no speedup).
    let r = PlaybackPacing.computeRate(depth: 0.2, velocity: 0.0)
    #expect(r.target == 1.0)
    #expect(r.p == 0.0)
}

@Test func pacing_midRange_targetIsApproxOneAndThreeQuarters() {
    // depth=0.85, target=0.2, panic=1.5 → P=(0.85-0.2)/1.3=0.5
    // target = 1.0 + 0.5 * (2.5 - 1.0) = 1.75
    let r = PlaybackPacing.computeRate(depth: 0.85, velocity: 0.0)
    #expect(abs(r.target - 1.75) < 0.0001)
    #expect(abs(r.p - 0.5) < 0.0001)
}

@Test func pacing_atPanic_targetSaturatesAtMax() {
    let r = PlaybackPacing.computeRate(depth: 1.5, velocity: 0.0)
    #expect(r.target == 2.5)
    #expect(r.p == 1.0)
}
