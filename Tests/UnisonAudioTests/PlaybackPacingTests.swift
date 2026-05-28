import Foundation
import Testing
@testable import UnisonAudio

// Tests for the lenient pacing v3 (after the harness-data review).
// Constants for reference (kept in sync with PlaybackPacing.swift):
//   targetBufferSec  = 1.0
//   maxRate          = 1.5
//   minRate          = 1.0
//   correctionGain   = 0.3

// MARK: - targetRate

@Test func pacing_atBufferTarget_targetMatchesArrival() {
    // At exactly targetBufferSec (1.0 s), correction = 0 → rate matches arrival.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 1.0)
    #expect(r.bufferError == 0.0)
    #expect(r.correction == 0.0)
    #expect(r.clampedTarget == 1.0)
}

@Test func pacing_belowTarget_targetFloorsAtOne() {
    // Normal operation (depth 0.2 s, well below 1.0 s target):
    // bufferError = -0.8, correction = -0.24, unbounded = 0.76 → clamps to 1.0.
    // The controller is a no-op at typical buffer depths — this is the
    // intent of the lenient v3 thresholds.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 0.2)
    #expect(r.unboundedTarget < 1.0)
    #expect(r.clampedTarget == 1.0)
}

@Test func pacing_mildOverTarget_gentleSpeedup() {
    // Buffer 2.0 s (over target by 1.0) → correction = 0.3 → target = 1.3.
    // Mild ramp-up, well below the 1.5 ceiling — gives the buffer time
    // to drain without aggressive time-stretching.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 2.0)
    #expect(abs(r.bufferError - 1.0) < 0.0001)
    #expect(abs(r.correction - 0.3) < 0.0001)
    #expect(abs(r.clampedTarget - 1.3) < 0.0001)
}

@Test func pacing_severeOverTarget_saturatesAtMaxRate() {
    // Buffer 3.0 s (excess 2.0) + arrival 1.0× → unbounded = 1.0 + 0.6 = 1.6.
    // Clamps to maxRate = 1.5. This is the safety-net regime — should
    // never trigger on typical OpenAI Realtime sessions.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 3.0)
    #expect(r.unboundedTarget > 1.5)
    #expect(r.clampedTarget == 1.5)
}

@Test func pacing_arrivalSlightlyAboveOne_lowDepth_stillRateOne() {
    // Verbose target language case: arrival 1.05× wall-clock, buffer near
    // empty. Correction negative pulls unbounded below arrival, but the
    // 1.0 floor + 1.0 minRate keep us at 1.0. We follow the arrival rate
    // only when buffer is at or above target.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.05, depthSmooth: 0.2)
    // unbounded = 1.05 + (0.2 - 1.0) × 0.3 = 1.05 - 0.24 = 0.81 → floor 1.0
    #expect(r.clampedTarget == 1.0)
}

@Test func pacing_slowArrival_targetStillFloorsAtOne() {
    // Pathological case: model emits slower than real-time (0.7×).
    // We never slow below 1.0 — that would let the buffer overflow
    // indefinitely. Underrun is the unavoidable consequence; pacing
    // can't fix what isn't being emitted.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.7, depthSmooth: 1.0)
    #expect(r.clampedTarget == 1.0)
}

// MARK: - slewToward

@Test func pacing_slew_upBySmallStep() {
    // current=1.0, target=1.5, maxStep=0.05 → next=1.05 (one tick).
    let next = PlaybackPacing.slewToward(currentRate: 1.0, target: 1.5, maxStep: 0.05)
    #expect(abs(next - 1.05) < 0.0001)
}

@Test func pacing_slew_downBySmallStep() {
    // current=1.5, target=1.0, maxStep=0.05 → next=1.45 (one tick).
    let next = PlaybackPacing.slewToward(currentRate: 1.5, target: 1.0, maxStep: 0.05)
    #expect(abs(next - 1.45) < 0.0001)
}

@Test func pacing_slew_closeEnough_noOvershoot() {
    let next = PlaybackPacing.slewToward(currentRate: 1.02, target: 1.04, maxStep: 0.05)
    #expect(abs(next - 1.04) < 0.0001)
}

@Test func pacing_slew_atTarget_unchanged() {
    let next = PlaybackPacing.slewToward(currentRate: 1.2, target: 1.2, maxStep: 0.05)
    #expect(next == 1.2)
}
