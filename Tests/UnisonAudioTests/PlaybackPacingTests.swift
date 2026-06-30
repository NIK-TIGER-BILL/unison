import Foundation
import Testing
@testable import UnisonAudio

// Tests for bidirectional pacing v4 (matches the model's sub-real-time
// arrival around a thin buffer setpoint instead of flooring at 1.0×).
// Constants (kept in sync with PlaybackPacing.swift):
//   targetBufferSec  = 0.15
//   maxRate          = 1.5
//   minRate          = 0.85
//   correctionGain   = 0.4

// MARK: - targetRate

@Test func pacing_atSetpoint_targetMatchesArrival() {
    // At exactly targetBufferSec, correction = 0 → rate == arrival.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.95, depthSmooth: PlaybackPacing.targetBufferSec)
    #expect(abs(r.bufferError) < 1e-9)
    #expect(abs(r.correction) < 1e-9)
    #expect(abs(r.clampedTarget - 0.95) < 1e-9)
}

@Test func pacing_subRealtimeArrival_followsArrival_notFlooredAtOne() {
    // THE v4 fix: model emits at 0.95× and the buffer is at setpoint → we
    // PLAY at 0.95× (match arrival) instead of the old hard 1.0× that
    // out-ran the source and drained the buffer to silence. Consumption ==
    // arrival ⇒ no underrun and no latency growth.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.95, depthSmooth: PlaybackPacing.targetBufferSec)
    #expect(r.clampedTarget < 1.0)
    #expect(abs(r.clampedTarget - 0.95) < 1e-9)
}

@Test func pacing_bufferDraining_easesBelowArrivalToRebuild() {
    // Buffer below setpoint (0.05 < 0.15) → ease slightly below arrival to
    // rebuild the thin cushion, never below minRate.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.95, depthSmooth: 0.05)
    #expect(r.bufferError < 0)
    #expect(r.clampedTarget < 0.95)            // slower than arrival → rebuilds
    #expect(r.clampedTarget >= PlaybackPacing.minRate)
}

@Test func pacing_criticallyEmpty_clampsAtMinRate_notBelow() {
    // Low arrival + empty buffer pushes the raw target below the floor;
    // it clamps at minRate (0.85), the safety margin.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.80, depthSmooth: 0.0)
    #expect(r.unboundedTarget < PlaybackPacing.minRate)
    #expect(r.clampedTarget == PlaybackPacing.minRate)
}

@Test func pacing_overSetpoint_speedsUpToDrain() {
    // Buffer above setpoint (burst) → speed up above arrival to drain,
    // keeping latency bounded.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0, depthSmooth: 0.5)
    #expect(r.bufferError > 0)
    #expect(r.clampedTarget > 1.0)
    #expect(r.clampedTarget <= PlaybackPacing.maxRate)
}

@Test func pacing_severeOverSetpoint_saturatesAtMaxRate() {
    // A large sustained buffer (burst / verbose target) saturates the
    // drain rate at maxRate.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.2, depthSmooth: 3.0)
    #expect(r.unboundedTarget > PlaybackPacing.maxRate)
    #expect(r.clampedTarget == PlaybackPacing.maxRate)
}

// MARK: - Emergent behaviour over a synthetic timeline

@Test func pacing_subRealtimeTimeline_noSustainedUnderrun_andThinLatency() {
    // Replay the production rate math over 60 s of steady 0.95× arrival
    // (the observed model cadence). v3 (floor 1.0×) would out-run the
    // source and underrun continuously; v4 should rebuild a thin buffer,
    // settle at consumption ≈ arrival, and hold latency near the setpoint.
    let dt = PlaybackPacing.tickIntervalSec
    let sr = 48_000.0
    let dtSamples = dt * sr
    let arrivalRate = 0.95

    var scheduled = 0.0, completed = 0.0, prevSched = 0.0
    var arrivalEMA = 1.0, depthSmooth = 0.0, applied = 1.0
    var steadyTicks = 0, steadyUnderruns = 0
    var lastDepth = 0.0

    for tick in 0..<600 {
        scheduled += arrivalRate * dtSamples                 // steady sub-real-time delivery
        let want = applied * dtSamples
        let avail = scheduled - completed
        let consumed = min(want, avail)
        completed += consumed
        let depth = max(0, scheduled - completed) / sr

        let instArrival = (scheduled - prevSched) / dtSamples
        prevSched = scheduled
        arrivalEMA += (instArrival - arrivalEMA) * PlaybackPacing.arrivalRateAlpha
        depthSmooth += (depth - depthSmooth) * PlaybackPacing.depthSmoothAlpha

        let st = PlaybackPacing.targetRate(arrivalRateEMA: arrivalEMA, depthSmooth: depthSmooth)
        applied = PlaybackPacing.slewToward(currentRate: applied, target: st.clampedTarget,
                                            maxStep: PlaybackPacing.maxRateStepPerTick)

        if tick > 200 {                                       // after warm-up / EMA convergence
            steadyTicks += 1
            if consumed < want - 1e-6 { steadyUnderruns += 1 }
            lastDepth = depth
        }
    }

    let underrunPct = Double(steadyUnderruns) / Double(steadyTicks) * 100.0
    #expect(underrunPct < 2.0, "steady-state underrun \(underrunPct)% — controller still out-runs arrival")
    // Latency-neutral: the buffer holds near the thin setpoint, not blown up.
    #expect(lastDepth > 0.05 && lastDepth < 0.40, "steady depth \(lastDepth)s drifted off the setpoint")
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
