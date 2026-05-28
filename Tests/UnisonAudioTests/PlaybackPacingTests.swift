import Foundation
import Testing
@testable import UnisonAudio

// MARK: - targetRate

@Test func pacing_atBufferTarget_targetMatchesArrival() {
    // At exactly the desired buffer depth (0.4 s), correction = 0, so
    // the player should simply match the arrival rate.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 0.4)
    #expect(r.bufferError == 0.0)
    #expect(r.correction == 0.0)
    #expect(r.clampedTarget == 1.0)
}

@Test func pacing_arrivalAboveOne_targetTracksArrival() {
    // Fast speaker: model emits at 1.3× wall-clock, buffer at target.
    // Player needs to consume at 1.3× to keep up. No correction.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.3, depthSmooth: 0.4)
    #expect(abs(r.clampedTarget - 1.3) < 0.0001)
}

@Test func pacing_bufferOverTarget_targetGetsCorrection() {
    // Buffer 1.0 s (over target by 0.6) → correction = +0.6.
    // Player rate = arrival (1.0) + correction (0.6) = 1.6.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 1.0)
    #expect(abs(r.bufferError - 0.6) < 0.0001)
    #expect(abs(r.clampedTarget - 1.6) < 0.0001)
}

@Test func pacing_bufferPanic_targetSaturatesAtMax() {
    // Buffer 1.5 s + arrival 1.5× → unbounded target = 1.5 + 1.1 = 2.6.
    // Clamped to maxRate 2.5.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.5, depthSmooth: 1.5)
    #expect(r.unboundedTarget > 2.5)
    #expect(r.clampedTarget == 2.5)
}

@Test func pacing_bufferEmpty_targetFloorsAtOne() {
    // Buffer near 0 (underrun risk). Correction = -0.4 × 1.0 = -0.4.
    // Unbounded target = 1.0 - 0.4 = 0.6 → clamped to minRate 1.0.
    // This is the critical invariant: we NEVER slow below real-time.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 0.0)
    #expect(r.unboundedTarget < 1.0)
    #expect(r.clampedTarget == 1.0)
}

@Test func pacing_slowArrival_targetStillFloorsAtOne() {
    // Pathological case: model emits slower than real-time (0.7×).
    // We still cannot go below 1.0 — the floor protects against
    // buffer overflow. The slow arrival eventually empties the
    // buffer; underrun is unavoidable in this case but the rate
    // never goes below realtime.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.7, depthSmooth: 0.4)
    #expect(r.clampedTarget == 1.0)
}

// MARK: - slewToward

@Test func pacing_slew_upBySmallStep() {
    // current=1.0, target=2.5, maxStep=0.05 → next=1.05 (capped).
    let next = PlaybackPacing.slewToward(currentRate: 1.0, target: 2.5, maxStep: 0.05)
    #expect(abs(next - 1.05) < 0.0001)
}

@Test func pacing_slew_downBySmallStep() {
    // current=2.0, target=1.0, maxStep=0.05 → next=1.95.
    let next = PlaybackPacing.slewToward(currentRate: 2.0, target: 1.0, maxStep: 0.05)
    #expect(abs(next - 1.95) < 0.0001)
}

@Test func pacing_slew_closeEnough_noOvershoot() {
    // current=1.02, target=1.04, maxStep=0.05 → reaches target without overshoot.
    let next = PlaybackPacing.slewToward(currentRate: 1.02, target: 1.04, maxStep: 0.05)
    #expect(abs(next - 1.04) < 0.0001)
}

@Test func pacing_slew_atTarget_unchanged() {
    let next = PlaybackPacing.slewToward(currentRate: 1.5, target: 1.5, maxStep: 0.05)
    #expect(next == 1.5)
}
