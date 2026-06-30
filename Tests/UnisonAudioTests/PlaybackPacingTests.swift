import Foundation
import Testing
@testable import UnisonAudio

// Tests for asymmetric pacing v5: baseline 1.0×, never slower; only ever
// speed UP (gently) to drain a buffer grown past the setpoint. The target
// is `1.0 + correction`, arrival rate is NOT in the formula.
// Constants (kept in sync with PlaybackPacing.swift):
//   targetBufferSec  = 0.75   (deadband edge; env UNISON_BUFFER_MS)
//   maxRate          = 1.06
//   minRate          = 1.00   (hard floor — never slow below real-time)
//   correctionGain   = 0.4
//   depthSmoothAlpha = 0.15

// MARK: - targetRate

@Test func pacing_atSetpoint_rateIsExactlyOne() {
    // At exactly targetBufferSec, correction = 0 → rate == 1.0×, regardless
    // of arrival rate (v5 ignores arrival in the formula).
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.95, depthSmooth: PlaybackPacing.targetBufferSec)
    #expect(abs(r.bufferError) < 1e-9)
    #expect(abs(r.correction) < 1e-9)
    #expect(abs(r.clampedTarget - 1.0) < 1e-9)
}

@Test func pacing_arrivalRateDoesNotChangeTarget() {
    // v5 invariant: the target depends ONLY on buffer depth, never on the
    // arrival-rate EMA. Same depth + wildly different arrival ⇒ same target.
    // Use a depth above the setpoint so the rate is mid-range (not pinned at
    // the floor), making the arrival-independence assertion meaningful.
    let d = PlaybackPacing.targetBufferSec + 0.2
    let slow = PlaybackPacing.targetRate(arrivalRateEMA: 0.80, depthSmooth: d)
    let fast = PlaybackPacing.targetRate(arrivalRateEMA: 1.40, depthSmooth: d)
    #expect(abs(slow.clampedTarget - fast.clampedTarget) < 1e-9)
}

@Test func pacing_subRealtimeArrival_neverSlowsBelowOne() {
    // THE v5 fix vs v4: even when the model emits at 0.95× and the buffer is
    // at setpoint, we play at exactly 1.0× — never below. v4 played 0.95×
    // here, which both added latency and produced the "robotic" time-stretch
    // the user reported. v5 keeps playback pitch-perfect.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.95, depthSmooth: PlaybackPacing.targetBufferSec)
    #expect(r.clampedTarget == 1.0)
}

@Test func pacing_bufferBelowSetpoint_holdsAtOne_neverSlows() {
    // Buffer below setpoint (0.05 < 0.30) → raw target would dip below 1.0,
    // but v5 clamps it to the 1.0 floor. We do NOT slow to "rebuild" (that
    // was v4, and it stretched audio for no underrun benefit); the buffer
    // rebuilds on its own whenever arrival ≥ 1.0×.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.95, depthSmooth: 0.05)
    #expect(r.bufferError < 0)
    #expect(r.unboundedTarget < 1.0)               // negative correction…
    #expect(r.clampedTarget == 1.0)                // …clamped away by the floor
}

@Test func pacing_criticallyEmpty_clampsAtMinRate_notBelow() {
    // Empty buffer drives the raw target well below the floor; it clamps at
    // minRate (= 1.0 in v5), never slower than real-time.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 0.80, depthSmooth: 0.0)
    #expect(r.unboundedTarget < PlaybackPacing.minRate)
    #expect(r.clampedTarget == PlaybackPacing.minRate)
    #expect(PlaybackPacing.minRate == 1.0)
}

@Test func pacing_overSetpoint_speedsUpToDrain() {
    // Buffer above setpoint (burst) → speed up above 1.0× to drain, keeping
    // latency bounded. Use a depth comfortably above the setpoint so this
    // holds regardless of the (env-tunable) targetBufferSec.
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.0,
                                      depthSmooth: PlaybackPacing.targetBufferSec + 0.3)
    #expect(r.bufferError > 0)
    #expect(r.clampedTarget > 1.0)
    #expect(r.clampedTarget <= PlaybackPacing.maxRate)
}

@Test func pacing_severeOverSetpoint_saturatesAtMaxRate() {
    // A large sustained buffer (big burst / verbose target) saturates the
    // drain rate at the GENTLE maxRate ceiling (1.06× — bounds the artefact).
    let r = PlaybackPacing.targetRate(arrivalRateEMA: 1.2, depthSmooth: 3.0)
    #expect(r.unboundedTarget > PlaybackPacing.maxRate)
    #expect(r.clampedTarget == PlaybackPacing.maxRate)
    #expect(PlaybackPacing.maxRate == 1.06)
}

// MARK: - Emergent behaviour over a synthetic timeline

@Test func pacing_jitteryRealtimeTimeline_lowUnderrun_boundedLatency_neverSlows() {
    // Replay the v5 controller over a synthetic arrival timeline that mirrors
    // the REAL recorded model cadence (see pacing-eval): 0.25 s audio chunks
    // whose inter-arrival gaps jitter around ~0.245 s (mean arrival ≈ 1.02×,
    // exactly the measured value) with bursts (0.12 s) and gaps (0.42 s).
    // v5 must keep underrun low, hold latency bounded near the 0.75 s
    // deadband edge (NOT ballooning like v4's ~0.96 s peak), and — the key
    // invariant — NEVER play below 1.0×.
    let dt = PlaybackPacing.tickIntervalSec       // 0.1
    let sr = 48_000.0
    let dtSamples = dt * sr
    let chunkSamples = 0.25 * sr                   // 0.25 s audio per chunk

    // Deterministic clause-bursty gaps mirroring the real timeline: tight
    // bursts (0.05–0.10 s, the model dumping a clause) that rapidly build
    // the cushion, interleaved with clause-boundary gaps (0.38–0.45 s) that
    // stress it. Mean ≈ 0.245 s (≈ 1.02× arrival — the measured value).
    let gaps = [0.05, 0.40, 0.08, 0.45, 0.06, 0.38, 0.10, 0.44]
    var arrivalTimes: [Double] = []
    var t = 0.5
    var gi = 0
    while t < 60.0 {
        arrivalTimes.append(t)
        t += gaps[gi % gaps.count]
        gi += 1
    }
    let totalTicks = 650
    var samplesPerTick = [Double](repeating: 0, count: totalTicks + 1)
    for at in arrivalTimes {
        let idx = min(totalTicks, Int(at / dt))
        samplesPerTick[idx] += chunkSamples
    }
    // Underruns are only meaningful while audio is still expected — i.e.
    // up to the last arrival. The post-stream drain (buffer emptying after
    // the model finished) is the natural end of playback, not a glitch.
    let lastArrivalTick = Int((arrivalTimes.last ?? 0) / dt)

    var scheduled = 0.0, completed = 0.0, prevSched = 0.0
    var arrivalEMA = 1.0, depthSmooth = 0.0, applied = 1.0
    var steadyTicks = 0, steadyUnderruns = 0
    var minRateSeen = 9.0, maxDepth = 0.0, depthSum = 0.0, depthN = 0

    for tick in 0..<totalTicks {
        scheduled += samplesPerTick[tick]
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

        if tick > 100 && tick <= lastArrivalTick {  // warm-up done, audio still expected
            steadyTicks += 1
            if consumed < want - 1e-6 { steadyUnderruns += 1 }
            minRateSeen = min(minRateSeen, applied)
            maxDepth = max(maxDepth, depth)
            depthSum += depth; depthN += 1
        }
    }

    let underrunPct = Double(steadyUnderruns) / Double(steadyTicks) * 100.0
    let meanDepth = depthSum / Double(depthN)
    let tgt = PlaybackPacing.targetBufferSec
    // v5 keeps the jittery stream mostly glitch-free…
    #expect(underrunPct < 5.0, "steady-state underrun \(underrunPct)% too high")
    // …never plays below real-time (the core v5 invariant)…
    #expect(minRateSeen >= 1.0 - 1e-9, "v5 must never slow below 1.0×, saw \(minRateSeen)")
    // …and holds latency bounded near the setpoint (no v4-style balloon).
    // Bounds are relative to the (env-tunable) setpoint: the controller holds
    // ~setpoint of cushion plus a little jitter headroom, and never balloons.
    #expect(maxDepth < tgt + 0.7, "peak latency \(maxDepth)s ballooned above setpoint \(tgt)s")
    #expect(meanDepth < tgt + 0.3, "mean latency \(meanDepth)s drifted too high above setpoint \(tgt)s")
}

// MARK: - buffer cushion

@Test func pacing_targetBufferSec_defaultsTo750ms() {
    // The drain-threshold / deadband edge defaults to 0.75 s — the top of the
    // model's natural queue depth, so the common depths play at exactly 1.0×
    // (no time-stretch, no on/off). Live-overridable via UNISON_BUFFER_MS.
    if ProcessInfo.processInfo.environment["UNISON_BUFFER_MS"] == nil {
        #expect(abs(PlaybackPacing.targetBufferSec - 0.75) < 1e-9)
    }
}

@Test func pacing_targetBufferSec_honorsEnvOverride() {
    // When UNISON_BUFFER_MS is set, the cushion must reflect it (ms → sec).
    // Only asserts when the env is present (the live-tuning path).
    if let raw = ProcessInfo.processInfo.environment["UNISON_BUFFER_MS"],
       let ms = Double(raw), ms >= 0 {
        #expect(abs(PlaybackPacing.targetBufferSec - ms / 1000.0) < 1e-9)
    }
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
