import Foundation
import Testing
@testable import UnisonAudio

// MARK: - Pure-function step tests

@Test func agc_firstFrame_bootstrapsLongTermRMS() {
    // First voiced frame should set longTermRMS directly (no slow
    // EMA ramp from 0), so gain converges immediately.
    let frame: [Float] = .init(repeating: 0.05, count: 4800)  // 100ms @ 48k, RMS=0.05
    let (state, _) = CompensatingAGC.processed(
        samples: frame, frameDurationSec: 0.1,
        state: .initial, config: .default)
    #expect(abs(state.longTermRMS - 0.05) < 0.001)
}

@Test func agc_atTarget_gainStaysAtOne() {
    // RMS already at target → desired gain = 1.0, no boost needed.
    let frame: [Float] = .init(repeating: 0.05, count: 4800)  // RMS=0.05 = target
    var state = AGCState.initial
    state.longTermRMS = 0.05
    let (newState, _) = CompensatingAGC.processed(
        samples: frame, frameDurationSec: 0.1,
        state: state, config: .default)
    #expect(abs(newState.currentGain - 1.0) < 0.05)
}

@Test func agc_fadedSignal_pullsGainUp() {
    // Simulated faded signal: RMS=0.015 (matches Q4 of our user data).
    // Target RMS 0.05 / 0.015 ≈ 3.33 → gain should ramp toward 3.33
    // but slew limit caps single-frame movement at 0.02.
    let frame: [Float] = .init(repeating: 0.015, count: 4800)
    var state = AGCState.initial
    state.longTermRMS = 0.015
    state.currentGain = 1.0
    let (newState, _) = CompensatingAGC.processed(
        samples: frame, frameDurationSec: 0.1,
        state: state, config: .default)
    // Slew limit: 1.0 + 0.02 = 1.02 (not the desired 3.33 in one tick).
    #expect(abs(newState.currentGain - 1.02) < 0.001)
}

@Test func agc_clampToMaxGain() {
    // Very low RMS would want huge gain (target/rms = 50×). Cap at maxGain=4.0.
    var state = AGCState.initial
    state.longTermRMS = 0.001
    state.currentGain = 3.99
    let frame: [Float] = .init(repeating: 0.001, count: 4800)
    let (newState, _) = CompensatingAGC.processed(
        samples: frame, frameDurationSec: 0.1,
        state: state, config: .default)
    #expect(newState.currentGain <= 4.0 + 0.001)
}

@Test func agc_silence_doesNotBoost_andAccumulatesPauseTime() {
    // Silence (RMS < floor 0.005) should pass through with unchanged gain
    // and accumulate silence time toward reset threshold.
    let silentFrame: [Float] = .init(repeating: 0.0001, count: 4800)
    var state = AGCState.initial
    state.currentGain = 2.5
    state.longTermRMS = 0.02
    state.silenceAccumSec = 0
    let (newState, out) = CompensatingAGC.processed(
        samples: silentFrame, frameDurationSec: 0.1,
        state: state, config: .default)
    // Gain unchanged.
    #expect(newState.currentGain == 2.5)
    // Long-term RMS unchanged (don't bias it down during silence).
    #expect(newState.longTermRMS == 0.02)
    // Silence accumulator advanced.
    #expect(newState.silenceAccumSec == 0.1)
    // Samples passed through unchanged (no boost during silence).
    #expect(out == silentFrame)
}

@Test func agc_longSilence_resetsState() {
    // Once silenceAccumSec exceeds resetSilenceSec, state snaps to initial.
    var state = AGCState.initial
    state.currentGain = 3.0
    state.longTermRMS = 0.02
    state.silenceAccumSec = 2.95
    let silentFrame: [Float] = .init(repeating: 0.0001, count: 4800)
    let (newState, _) = CompensatingAGC.processed(
        samples: silentFrame, frameDurationSec: 0.1,
        state: state, config: .default)
    #expect(newState == AGCState.initial)
}

@Test func agc_voicedFrameAfterReset_freshStart() {
    // After reset, the next voiced frame bootstraps longTermRMS fresh
    // (no carry-over from before the silence).
    var state = AGCState.initial
    let voiced: [Float] = .init(repeating: 0.06, count: 4800)
    let (newState, _) = CompensatingAGC.processed(
        samples: voiced, frameDurationSec: 0.1,
        state: state, config: .default)
    #expect(abs(newState.longTermRMS - 0.06) < 0.001)
    // RMS 0.06 > target 0.05 → desired gain < 1, clamped by minGain=1.0.
    #expect(newState.currentGain >= 1.0 - 0.001)
    _ = state
}

@Test func agc_slewLimit_smoothsLargeJump() {
    // Configure state so that desired gain is much larger than slew
    // can allow in one tick. longTermRMS=0.01 → desired = target/rms
    // = 5.0, clamped to maxGain=4.0, but slew caps single-tick change
    // at 0.02 — so we should land at 1.02 even though target is 4.0.
    var state = AGCState.initial
    state.longTermRMS = 0.01
    state.currentGain = 1.0
    let frame: [Float] = .init(repeating: 0.01, count: 4800)
    let (newState, _) = CompensatingAGC.processed(
        samples: frame, frameDurationSec: 0.1,
        state: state, config: .default)
    #expect(abs(newState.currentGain - 1.02) < 0.005)
}

// MARK: - Multi-frame integration

@Test func agc_fadingSession_recoversAmplitude() {
    // Simulate the user's observed fade pattern: starts at RMS 0.05,
    // decays linearly to 0.015 over 250 frames (= 25 seconds at 10
    // frames/sec). The AGC should ramp gain up over the session so
    // the OUTPUT RMS stays roughly stable near the target.
    var state = AGCState.initial
    var outputRMSs: [Double] = []
    let frames = 250  // 25 seconds at 100ms each
    for i in 0..<frames {
        let progress = Double(i) / Double(frames)
        let inRMS = 0.05 - progress * (0.05 - 0.015)  // linear fade
        let frame: [Float] = .init(repeating: Float(inRMS), count: 4800)
        let (newState, out) = CompensatingAGC.processed(
            samples: frame, frameDurationSec: 0.1,
            state: state, config: .default)
        state = newState
        // Output RMS of constant-value frame = |value| × gain
        let outRMS = Double(abs(out[0]))
        outputRMSs.append(outRMS)
    }
    // First few frames: roughly at-target (no fade yet, gain ~1).
    let firstAvg = outputRMSs[10..<30].reduce(0, +) / 20
    // Last few frames: gain should have ramped up to compensate.
    let lastAvg = outputRMSs[(frames-20)..<frames].reduce(0, +) / 20
    // We don't expect perfect restoration but the gap should narrow
    // significantly. Without AGC, last/first ratio would be 0.30
    // (0.015/0.05). With AGC ramping toward gain ~3.3, last/first
    // ratio should be much closer to 1.0.
    let ratio = lastAvg / firstAvg
    #expect(ratio > 0.6,
            "AGC should mostly restore amplitude (ratio went \(ratio) — needs to exceed 0.6)")
}
