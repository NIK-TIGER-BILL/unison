import Foundation
import Testing
@testable import UnisonAudio
import UnisonDomain

// StreamingResampler — the stateful, continuity-preserving counterpart of
// the one-shot `Resampler`. The static path `.reset()`s its cached
// AVAudioConverter before every chunk and drains it with `.endOfStream`,
// then truncates / zero-pads to the expected length: every chunk boundary
// gets a filter-warm-up transient plus injected zeros. On the send path the
// capture delivers ~10 ms frames → ~100 artificial seams per second in the
// audio the ENGINE hears; on the receive path it's one seam per model chunk.
// The streaming resampler keeps the converter's filter state across chunks —
// chunked output must be as smooth as converting the whole signal at once.

private func sineFrame(freq: Double, sampleRate: Int, start: Int, count: Int, amp: Float = 0.5) -> AudioFrame {
    var data = Data(count: count * 4)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Float.self).baseAddress!
        for i in 0..<count {
            p[i] = amp * Float(sin(2.0 * .pi * freq * Double(start + i) / Double(sampleRate)))
        }
    }
    return AudioFrame(pcm: data, sampleRate: sampleRate, channels: 1, format: .float32)
}

private func floats(_ frame: AudioFrame) -> [Float] {
    frame.pcm.withUnsafeBytes { raw in Array(raw.bindMemory(to: Float.self)) }
}

/// Max |x[i+1] − x[i]| — a discontinuity metric. For a pure sine the true
/// bound is 2π·f/sr·amp; a seam artifact (filter restart / zero-pad) shows
/// up as a step far above it.
private func maxStep(_ x: [Float]) -> Float {
    guard x.count > 1 else { return 0 }
    var m: Float = 0
    for i in 1..<x.count { m = max(m, abs(x[i] - x[i - 1])) }
    return m
}

@Test func streaming_upsample24to48_chunked_hasNoSeamSteps() {
    // 440 Hz sine at 24 kHz fed as 10 ms chunks (240 samples), upsampled to
    // 48 kHz. Sine max step at 48 kHz ≈ 2π·440/48000·0.5 ≈ 0.0288. Allow 2×
    // headroom for converter ripple. The one-shot path measured ~0.3+ steps
    // at seams (zero-pad against a mid-swing sine).
    let r = StreamingResampler()
    var out: [Float] = []
    for chunk in 0..<50 {
        let f = sineFrame(freq: 440, sampleRate: 24_000, start: chunk * 240, count: 240)
        let res = r.fromWire(f, targetSampleRate: 48_000)
        #expect(res.sampleRate == 48_000)
        #expect(res.format == .float32)
        out.append(contentsOf: floats(res))
    }
    let bound: Float = 2 * .pi * 440.0 / 48_000.0 * 0.5
    #expect(maxStep(out) < bound * 2,
            "chunk seams must be continuous: maxStep \(maxStep(out)) vs sine bound \(bound)")
    // Length: 50 × 240 in at ratio 2 → ~24000 out, minus bounded converter
    // latency (must not GROW with chunk count — that would be state leakage).
    #expect(out.count > 24_000 - 200 && out.count <= 24_000,
            "expected ≈24000 samples minus bounded latency, got \(out.count)")
}

@Test func streaming_downsample48to16_chunked_staysContinuous() {
    // The send path: 48 kHz capture → 16 kHz Gemini wire, 10 ms chunks
    // (480 samples). 300 Hz sine max step at 16 kHz ≈ 2π·300/16000·0.5 ≈
    // 0.0589.
    let r = StreamingResampler()
    var out: [Float] = []
    for chunk in 0..<50 {
        let f = sineFrame(freq: 300, sampleRate: 48_000, start: chunk * 480, count: 480)
        let wire = r.toWire(f, sampleRate: 16_000)
        #expect(wire.sampleRate == 16_000)
        #expect(wire.format == .int16)
        wire.pcm.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { out.append(Float(s) / 32_767.0) }
        }
    }
    let bound: Float = 2 * .pi * 300.0 / 16_000.0 * 0.5
    #expect(maxStep(out) < bound * 2,
            "send-path seams must be continuous: maxStep \(maxStep(out)) vs bound \(bound)")
    #expect(out.count > 8_000 - 200 && out.count <= 8_000)
}

@Test func streaming_oneShotStaticPath_hasSeamArtifacts_baseline() {
    // Baseline documenting WHY the streaming path exists: the same chunked
    // sine through the one-shot `Resampler` shows seam steps well above the
    // sine bound (filter restarts + zero-padding). If this ever starts
    // passing smoothly, the static path got fixed and the streaming class
    // can be re-evaluated.
    var out: [Float] = []
    for chunk in 0..<50 {
        let f = sineFrame(freq: 440, sampleRate: 24_000, start: chunk * 240, count: 240)
        out.append(contentsOf: floats(Resampler.fromWire(f, targetSampleRate: 48_000)))
    }
    let bound: Float = 2 * .pi * 440.0 / 48_000.0 * 0.5
    #expect(maxStep(out) > bound * 2,
            "one-shot path expected to show seam artifacts (got maxStep \(maxStep(out)))")
}

@Test func streaming_emptyFrame_passesThroughRetagged() {
    let r = StreamingResampler()
    let empty = AudioFrame(pcm: Data(), sampleRate: 24_000, channels: 1, format: .float32)
    let res = r.fromWire(empty, targetSampleRate: 48_000)
    #expect(res.sampleCount == 0)
    #expect(res.sampleRate == 48_000)
}

@Test func streaming_sameRate_fromWire_convertsFormatOnly() {
    let r = StreamingResampler()
    let f = sineFrame(freq: 440, sampleRate: 48_000, start: 0, count: 480)
    let res = r.fromWire(f, targetSampleRate: 48_000)
    #expect(res.sampleRate == 48_000)
    #expect(res.format == .float32)
    #expect(res.sampleCount == 480)
    #expect(floats(res) == floats(f))
}

@Test func streaming_makeStreamTransformer_returnsFreshInstancePerPipeline() {
    // The orchestrator asks its injected ResamplerAdapter for a per-pipeline
    // transformer so two concurrent streams (mic + peer at the same rate
    // pair) never share converter filter state.
    let adapter = ResamplerAdapter()
    let a = adapter.makeStreamTransformer()
    let b = adapter.makeStreamTransformer()
    #expect(a is StreamingResampler)
    #expect(b is StreamingResampler)
    #expect((a as AnyObject) !== (b as AnyObject))
}
