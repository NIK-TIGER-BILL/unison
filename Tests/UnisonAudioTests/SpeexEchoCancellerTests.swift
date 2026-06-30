import Foundation
import Testing
@testable import UnisonAudio
import UnisonDomain

// Deterministic noise so the convergence assertions never flake.
private struct LCG {
    var state: UInt64
    mutating func next() -> Float {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
    }
}

private func f32Frame(_ samples: [Float]) -> AudioFrame {
    var data = Data(count: samples.count * 4)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Float.self)
        for i in samples.indices { p[i] = samples[i] }
    }
    return AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32)
}

private func f32FrameAt(_ samples: [Float], rate: Int) -> AudioFrame {
    var data = Data(count: samples.count * 4)
    data.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Float.self)
        for i in samples.indices { p[i] = samples[i] }
    }
    return AudioFrame(pcm: data, sampleRate: rate, channels: 1, format: .float32)
}

private func samples(_ frame: AudioFrame) -> [Float] {
    var out = [Float](repeating: 0, count: frame.sampleCount)
    frame.pcm.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Float.self)
        for i in out.indices { out[i] = p[i] }
    }
    return out
}

private func rms(_ s: [Float]) -> Float {
    guard !s.isEmpty else { return 0 }
    return (s.reduce(0) { $0 + $1 * $1 } / Float(s.count)).squareRoot()
}

@Test func speex_silentFar_preservesNear() {
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 1)
    let block = 480
    let near = (0..<block).map { _ in lcg.next() * 0.3 }
    // Far is silence → nothing correlated to remove → near passes through.
    aec.pushFarReference(f32Frame([Float](repeating: 0, count: block)))
    let out = samples(aec.processNear(f32Frame(near)))
    #expect(out.count == block)
    #expect(abs(rms(out) - rms(near)) < 0.05)
}

@Test func speex_cancelsCorrelatedEcho() {
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 42)
    let block = 480
    var inRMS: Float = 0, outRMS: Float = 0
    // Echo-only scenario: mic hears exactly what was played. After the
    // filter converges, the residual should be a fraction of the input.
    for i in 0..<400 {
        let far = (0..<block).map { _ in lcg.next() * 0.3 }
        aec.pushFarReference(f32Frame(far))
        let out = samples(aec.processNear(f32Frame(far)))   // near == far
        if i >= 350 { inRMS += rms(far); outRMS += rms(out) }
    }
    // ≥ ~6 dB echo return loss enhancement after convergence.
    #expect(outRMS < inRMS * 0.5)
}

@Test func speex_doubleTalk_preservesNearVoice() {
    let aec = SpeexEchoCanceller()
    var farGen = LCG(state: 7), nearGen = LCG(state: 99)
    let block = 480
    var nearVoiceRMS: Float = 0, outRMS: Float = 0
    for i in 0..<400 {
        let far = (0..<block).map { _ in farGen.next() * 0.3 }
        let voice = (0..<block).map { _ in nearGen.next() * 0.2 }
        let mic = zip(voice, far).map(+)         // user voice + acoustic echo
        aec.pushFarReference(f32Frame(far))
        let out = samples(aec.processNear(f32Frame(mic)))
        if i >= 350 { nearVoiceRMS += rms(voice); outRMS += rms(out) }
    }
    // Output should track the near voice (echo removed), not be crushed to
    // silence and not still carry the full echo.
    #expect(outRMS > nearVoiceRMS * 0.5)
    #expect(outRMS < nearVoiceRMS * 1.8)
}

@Test func speex_reset_restoresPassthrough() {
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 3)
    let block = 480
    for _ in 0..<100 {
        let far = (0..<block).map { _ in lcg.next() * 0.3 }
        aec.pushFarReference(f32Frame(far))
        _ = aec.processNear(f32Frame(far))
    }
    aec.reset()
    let near = (0..<block).map { _ in lcg.next() * 0.3 }
    aec.pushFarReference(f32Frame([Float](repeating: 0, count: block)))
    let out = samples(aec.processNear(f32Frame(near)))
    #expect(abs(rms(out) - rms(near)) < 0.08)
}

@Test func speex_reblocks_oddSizedFrames() {
    let aec = SpeexEchoCanceller()
    // 500-sample near with no full pending → 480 out, 20 carried.
    aec.pushFarReference(f32Frame([Float](repeating: 0, count: 500)))
    let out = aec.processNear(f32Frame([Float](repeating: 0.1, count: 500)))
    #expect(out.sampleCount == 480)
    #expect(out.sampleRate == 48_000)
    #expect(out.format == .float32)
}

@Test func speex_tracksFarUnderrun_whenNoReferenceQueued() {
    let aec = SpeexEchoCanceller()
    // No pushFarReference → the one near block underruns the empty ring.
    _ = aec.processNear(f32Frame([Float](repeating: 0.1, count: 480)))
    #expect(aec.underrunFarSamples == 480)
}

@Test func speex_tracksFarDrop_onRingOverflow() {
    let aec = SpeexEchoCanceller()   // default ringCapacity 32768
    // One oversized far push: 40k samples can't fit → 40000-32768 dropped.
    aec.pushFarReference(f32Frame([Float](repeating: 0.1, count: 40_000)))
    #expect(aec.droppedFarSamples == 40_000 - 32_768)
}

@Test func speex_resamplesNonNativeMicRate_preservesDuration() {
    // Regression for the 48 kHz-assumption bug: a 16 kHz mic frame must come
    // out at 48 kHz with the SAME duration. 1600 samples @16k = 100 ms →
    // ~4800 samples @48k (minus a <480 reblock remainder). The old code
    // relabeled 1600 samples as 48 kHz (≈33 ms) → toWire shipped 3×-fast audio.
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 11)
    let near16k = (0..<1600).map { _ in lcg.next() * 0.2 }
    aec.pushFarReference(f32FrameAt([Float](repeating: 0, count: 4410), rate: 44_100))
    let out = aec.processNear(f32FrameAt(near16k, rate: 16_000))
    // Output tagged at the MIC rate with ~the same count (duration preserved at
    // that rate). The bug labeled it 48 kHz → toWire shipped 1/3-duration audio.
    #expect(out.sampleRate == 16_000)
    #expect(out.sampleCount > 1600 - 160)
    #expect(out.sampleCount <= 1600)
}

@Test func speex_cancelsEcho_acrossDeviceRates() {
    // The live default: 44.1 kHz output device + 16 kHz mic. The mic captures
    // the speaker output as a CONTINUOUS 16 kHz stream (the echo). Build near
    // as one continuous downsample of far, then feed both frame-by-frame; with
    // LTI resampling Speex must still cancel (the round-2 regression: stateless
    // per-chunk resampling gave ~0 dB here).
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 71)
    let frames = 800
    let far44 = (0..<(frames * 441)).map { _ in lcg.next() * 0.3 }   // continuous @44.1k
    // Echo the mic hears: far downsampled to 16k, delayed by a realistic
    // speaker→mic acoustic delay (10 ms) so the far reference leads the echo
    // (causal — a real session always has this lead).
    let echo = samples(Resampler.resampleToMonoF32(
        f32FrameAt(far44, rate: 44_100), targetSampleRate: 16_000))
    let near16 = [Float](repeating: 0, count: 160) + echo
    var inRMS: Float = 0, outRMS: Float = 0
    for i in 0..<frames {
        let f = Array(far44[(i * 441)..<((i + 1) * 441)])
        let nStart = i * 160, nEnd = min((i + 1) * 160, near16.count)
        guard nStart < nEnd else { break }
        let nFrame = Array(near16[nStart..<nEnd])
        aec.pushFarReference(f32FrameAt(f, rate: 44_100))
        let out = samples(aec.processNear(f32FrameAt(nFrame, rate: 16_000)))
        if i >= frames - 100 { inRMS += rms(nFrame); outRMS += rms(out) }
    }
    #expect(outRMS < inRMS * 0.3)   // strong cancellation once far is band-limited to the mic rate
}

@Test func speex_nonNativeNear_withSilentFar_preservesVoice() {
    // AEC must not eat the voice just because device rates differ: a 16 kHz
    // near against a silent 44.1 kHz far passes through (RMS preserved).
    let aec = SpeexEchoCanceller()
    var lcg = LCG(state: 13)
    let near16k = (0..<3200).map { _ in lcg.next() * 0.3 }   // 200 ms @16k, RMS≈0.17
    aec.pushFarReference(f32FrameAt([Float](repeating: 0, count: 8820), rate: 44_100))
    let out = samples(aec.processNear(f32FrameAt(near16k, rate: 16_000)))
    #expect(rms(out) > 0.1)
}
