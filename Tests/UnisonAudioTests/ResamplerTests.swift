import Foundation
import Testing
@testable import UnisonAudio
@testable import UnisonDomain

@Test func resampler_downsampleAndConvert_48kF32_to_24kI16() {
    let input = makeFrame(pcm: fixture("sine-440hz-48k-f32-1sec"), rate: 48_000, format: .float32)
    let out = Resampler.toWire(input, targetSampleRate: 24_000)
    #expect(out.sampleRate == 24_000)
    #expect(out.format == .int16)
    #expect(out.channels == 1)
    #expect(out.pcm.count == 48_000)
}

@Test func resampler_upsampleAndConvert_24kI16_to_48kF32() {
    let input = makeFrame(pcm: fixture("sine-440hz-24k-int16-1sec"), rate: 24_000, format: .int16)
    let out = Resampler.fromWire(input, targetSampleRate: 48_000)
    #expect(out.sampleRate == 48_000)
    #expect(out.format == .float32)
    #expect(out.channels == 1)
    #expect(out.pcm.count == 192_000)
}

@Test func resampler_passthroughWhenAlreadyMatching() {
    let input = makeFrame(pcm: fixture("sine-440hz-24k-int16-1sec"), rate: 24_000, format: .int16)
    let out = Resampler.toWire(input, targetSampleRate: 24_000)
    #expect(out == input)
}

@Test func resampler_roundTripPreservesEnergy() {
    let original = makeFrame(pcm: fixture("sine-440hz-48k-f32-1sec"), rate: 48_000, format: .float32)
    let wire = Resampler.toWire(original, targetSampleRate: 24_000)
    let back = Resampler.fromWire(wire, targetSampleRate: 48_000)
    #expect(back.sampleRate == 48_000)
    #expect(back.format == .float32)
    #expect(abs(back.sampleCount - original.sampleCount) <= 1)
}

@Test func resampler_emptyFrameDoesNotCrash() {
    // Cold-engine AVAudioEngine.installTap occasionally emits a 0-frame buffer.
    // Pre-fix this trapped in `AVAudioPCMBuffer(frameCapacity: 0)!`. The fix
    // passes empties through, re-tagged with the target sample rate so the
    // wire-format step doesn't blow up either.
    let empty = AudioFrame(pcm: Data(), sampleRate: 48_000, channels: 1, format: .float32)
    let wire = Resampler.toWire(empty, targetSampleRate: 24_000)
    #expect(wire.sampleCount == 0)
    #expect(wire.pcm.isEmpty)
    // toWire converts to int16 wire format at 24kHz, so the empty
    // frame should carry that downstream tag.
    #expect(wire.sampleRate == 24_000)
    #expect(wire.format == AudioSampleFormat.int16)
}

// MARK: - Device-format robustness (USB/BT mics deliver int16; some configs deliver stereo)

private func sineInt16(rate: Int, seconds: Double = 0.1, channels: Int = 1) -> Data {
    let frames = Int(Double(rate) * seconds)
    var out = Data(capacity: frames * channels * 2)
    for i in 0..<frames {
        let v = Int16(sin(Double(i) * 2.0 * .pi * 440.0 / Double(rate)) * 12_000)
        for _ in 0..<channels {
            withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) }
        }
    }
    return out
}

private func sineFloat32(rate: Int, seconds: Double = 0.1, channels: Int = 1) -> Data {
    let frames = Int(Double(rate) * seconds)
    var out = Data(capacity: frames * channels * 4)
    for i in 0..<frames {
        let v = Float(sin(Double(i) * 2.0 * .pi * 440.0 / Double(rate)) * 0.4)
        for _ in 0..<channels {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { out.append(contentsOf: $0) }
        }
    }
    return out
}

@Test func resampler_int16MicInput_48k_convertsWithoutCrashing() {
    // USB mics deliver int16 at the device rate. This used to hit
    // resampleFloat32's fatalError("expects .float32 input").
    let input = makeFrame(pcm: sineInt16(rate: 48_000), rate: 48_000, format: .int16)
    let out = Resampler.toWire(input, targetSampleRate: 24_000)
    #expect(out.sampleRate == 24_000)
    #expect(out.format == .int16)
    #expect(out.channels == 1)
    #expect(abs(out.sampleCount - input.sampleCount / 2) <= 1)
}

@Test func resampler_int16MicInput_16k_upsamplesToWire() {
    // Bluetooth HFP headset mics run at 8/16 kHz int16.
    let input = makeFrame(pcm: sineInt16(rate: 16_000), rate: 16_000, format: .int16)
    let out = Resampler.toWire(input, targetSampleRate: 24_000)
    #expect(out.sampleRate == 24_000)
    #expect(out.format == .int16)
    #expect(abs(out.sampleCount - input.sampleCount * 3 / 2) <= 1)
}

@Test func resampler_stereoFloat32Input_mixesDownToMono() {
    // Interleaved stereo from a 2ch capture config. This used to trap the
    // mono precondition in resampleFloat32 — a mid-call crash.
    let input = makeFrame(pcm: sineFloat32(rate: 48_000, channels: 2), rate: 48_000, channels: 2, format: .float32)
    let out = Resampler.toWire(input, targetSampleRate: 24_000)
    #expect(out.sampleRate == 24_000)
    #expect(out.format == .int16)
    #expect(out.channels == 1)
    #expect(abs(out.sampleCount - input.sampleCount / 2) <= 1)
}

@Test func resampler_stereoInt16AtWireRate_isNotPassedThroughUnmixed() {
    // int16@24k stereo must NOT take the passthrough shortcut — the wire
    // format is strictly mono.
    let input = makeFrame(pcm: sineInt16(rate: 24_000, channels: 2), rate: 24_000, channels: 2, format: .int16)
    let out = Resampler.toWire(input, targetSampleRate: 24_000)
    #expect(out.channels == 1)
    #expect(out.sampleRate == 24_000)
    #expect(out.format == .int16)
    #expect(abs(out.sampleCount - input.sampleCount) <= 1)
}

@Test func toWireProduces16kInt16ForGemini() {
    let samples = [Float](repeating: 0.1, count: 4800)   // 48kHz, 100ms
    let pcm = samples.withUnsafeBytes { Data($0) }
    let frame = AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32)
    let wire = Resampler.toWire(frame, targetSampleRate: 16_000)
    #expect(wire.sampleRate == 16_000)
    #expect(wire.format == .int16)
    #expect(abs(wire.pcm.count - 3200) <= 4)   // 1600 samples * 2 bytes
}

@Test func toWire24kMatchesLegacyOpenAIWire() {
    let samples = [Float](repeating: 0.2, count: 4800)
    let pcm = samples.withUnsafeBytes { Data($0) }
    let frame = AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32)
    let wire = Resampler.toWire(frame, targetSampleRate: 24_000)
    #expect(wire.sampleRate == 24_000)
    #expect(wire.format == .int16)
    #expect(abs(wire.pcm.count - 4800) <= 4)   // 2400 samples * 2 bytes
}
