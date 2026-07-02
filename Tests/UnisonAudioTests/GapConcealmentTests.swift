import Foundation
import Testing
@testable import UnisonAudio

// Gap concealment — NetEq-style loss masking, the "right medicine" for the
// residual micropauses the jitter buffer can't cover (sustained model
// slowdowns; ~3.8 % of ticks in the field measurements). When the player is
// about to run dry mid-speech, we schedule ONE short synthetic buffer built
// from the last pitch period of real audio, faded to zero: the hard cut
// becomes a natural-sounding decay, and when real audio resumes the seam
// declick ramps it back in from silence.

private func sine(freq: Double, sampleRate: Int, count: Int, amp: Float = 0.5) -> [Float] {
    (0..<count).map { amp * Float(sin(2.0 * .pi * freq * Double($0) / Double(sampleRate))) }
}

/// Deterministic pseudo-noise (LCG) — no seeding APIs needed in tests.
private func noise(count: Int, amp: Float = 0.5) -> [Float] {
    var state: UInt64 = 0x1234_5678
    return (0..<count).map { _ in
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Float(state >> 40) / Float(1 << 24)   // [0, 1)
        return amp * (unit * 2 - 1)
    }
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(Float(0)) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

// MARK: - Pitch estimation

@Test func pitch_pureSine_findsPeriod() {
    // 200 Hz at 48 kHz → period exactly 240 samples.
    let tail = sine(freq: 200, sampleRate: 48_000, count: 1_920)
    let p = GapConcealment.estimatePitchPeriod(tail: tail, sampleRate: 48_000)
    #expect(p != nil)
    if let p { #expect(abs(p - 240) <= 2, "expected ≈240, got \(p)") }
}

@Test func pitch_typicalVoiceRange_covered() {
    // 90 Hz (low male) → 533; 350 Hz (high female) → 137.
    let low = GapConcealment.estimatePitchPeriod(
        tail: sine(freq: 90, sampleRate: 48_000, count: 1_920), sampleRate: 48_000)
    let high = GapConcealment.estimatePitchPeriod(
        tail: sine(freq: 350, sampleRate: 48_000, count: 1_920), sampleRate: 48_000)
    if let low { #expect(abs(low - 533) <= 5) } else { Issue.record("90 Hz not detected") }
    if let high { #expect(abs(high - 137) <= 3) } else { Issue.record("350 Hz not detected") }
}

@Test func pitch_whiteNoise_returnsNil() {
    let p = GapConcealment.estimatePitchPeriod(tail: noise(count: 1_920), sampleRate: 48_000)
    #expect(p == nil, "unvoiced signal must not report a pitch (got \(String(describing: p)))")
}

@Test func pitch_silence_returnsNil() {
    let p = GapConcealment.estimatePitchPeriod(
        tail: [Float](repeating: 0, count: 1_920), sampleRate: 48_000)
    #expect(p == nil)
}

// MARK: - Concealment buffer synthesis

@Test func conceal_voicedTail_continuesPeriodAndFadesToZero() {
    let sampleRate = 48_000
    let tail = sine(freq: 200, sampleRate: sampleRate, count: 1_920)
    guard let buf = GapConcealment.makeConcealment(tail: tail, sampleRate: sampleRate,
                                                   durationSec: 0.2) else {
        Issue.record("voiced tail must produce a concealment buffer")
        return
    }
    #expect(buf.count == Int(0.2 * Double(sampleRate)))
    // Continues the waveform: the first sample follows the tail's last one
    // by exactly one period step (concealment[0] == tail[count − period]).
    #expect(abs(buf[0] - tail[1_920 - 240]) < 1e-4)
    // No discontinuity spikes inside the concealment: for a tiled 200 Hz
    // sine the step bound is 2π·200/48000·amp ≈ 0.0131; fading only shrinks
    // steps. Allow 2× for envelope interplay.
    var maxStep: Float = 0
    for i in 1..<buf.count { maxStep = max(maxStep, abs(buf[i] - buf[i - 1])) }
    #expect(maxStep < 0.0131 * 2, "tiling seams must be smooth, maxStep=\(maxStep)")
    // Fades: the first quarter carries real energy, the last quarter is
    // near-silence, and the very end is (almost) exactly zero.
    let n = buf.count
    #expect(rms(buf[0..<(n / 4)]) > rms(buf[(3 * n / 4)..<n]) * 4)
    #expect(abs(buf[n - 1]) < 0.01)
}

@Test func conceal_unvoicedTail_stillFadesOut() {
    // No pitch (fricative/noise) → block-repeat fallback, still a smooth
    // fade to zero rather than a hard cut.
    let tail = noise(count: 1_920, amp: 0.3)
    guard let buf = GapConcealment.makeConcealment(tail: tail, sampleRate: 48_000,
                                                   durationSec: 0.2) else {
        Issue.record("unvoiced tail must still produce a concealment buffer")
        return
    }
    let n = buf.count
    #expect(n == 9_600)
    #expect(rms(buf[0..<(n / 4)]) > rms(buf[(3 * n / 4)..<n]) * 4)
    #expect(abs(buf[n - 1]) < 0.01)
}

@Test func conceal_silentOrTinyTail_returnsNil() {
    // Nothing to continue — no concealment (scheduling silence over silence
    // is pointless).
    #expect(GapConcealment.makeConcealment(
        tail: [Float](repeating: 0, count: 1_920), sampleRate: 48_000, durationSec: 0.2) == nil)
    #expect(GapConcealment.makeConcealment(
        tail: sine(freq: 200, sampleRate: 48_000, count: 40), sampleRate: 48_000, durationSec: 0.2) == nil)
}
