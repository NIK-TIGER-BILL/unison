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
    #expect(r.d == 0.0)
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
    #expect(r.d == 0.0)
}

@Test func pacing_anticipatesGrowth_targetRisesEvenAtShallowQueue() {
    // depth=0.3 → P=(0.3-0.2)/1.3 ≈ 0.0769
    // velocity=+0.5 → D = clamp(0.5*1.5, ±0.5) = 0.5 (clamped)
    // target = 1.0 + (0.0769 + 0.5) * 1.5 ≈ 1.865
    let r = PlaybackPacing.computeRate(depth: 0.3, velocity: 0.5)
    #expect(r.target > 1.5)
    #expect(r.target < 2.0)
    #expect(r.d == 0.5)
}

@Test func pacing_drainingQueue_reducesTargetBelowPureProportional() {
    // depth=1.0, velocity=-0.5
    // P=(1.0-0.2)/1.3 ≈ 0.615
    // D = clamp(-0.5*1.5, ±0.5) = -0.5
    // target = 1.0 + (0.615 - 0.5) * 1.5 ≈ 1.173
    let withDrain = PlaybackPacing.computeRate(depth: 1.0, velocity: -0.5)
    let noDrain = PlaybackPacing.computeRate(depth: 1.0, velocity: 0.0)
    #expect(withDrain.target < noDrain.target)
    #expect(abs(withDrain.target - 1.173) < 0.01)
    #expect(withDrain.d == -0.5)
}

@Test func pacing_derivativeIsClamped_extremeVelocityDoesNotExplodeRate() {
    // velocity=10 is absurd. D should clamp to 0.5 not 15.
    // depth=0.2 (P=0). target = 1.0 + 0.5 * 1.5 = 1.75
    let r = PlaybackPacing.computeRate(depth: 0.2, velocity: 10.0)
    #expect(abs(r.target - 1.75) < 0.0001)
    #expect(r.d == 0.5)
}

@Test func pacing_attack_movesSeventyPercentTowardTarget() {
    // currentRate=1.0, target=2.5 → next = 1.0 + (2.5-1.0)*0.7 = 2.05
    let next = PlaybackPacing.smoothed(currentRate: 1.0, target: 2.5)
    #expect(abs(next - 2.05) < 0.0001)
}

@Test func pacing_release_movesFifteenPercentTowardTarget() {
    // currentRate=2.5, target=1.0 → next = 2.5 + (1.0-2.5)*0.15 = 2.275
    let next = PlaybackPacing.smoothed(currentRate: 2.5, target: 1.0)
    #expect(abs(next - 2.275) < 0.0001)
}

@Test func pacing_atTarget_smoothingIsIdentity() {
    // No change requested — output equals input regardless of which
    // factor would have applied.
    let next = PlaybackPacing.smoothed(currentRate: 1.5, target: 1.5)
    #expect(next == 1.5)
}
