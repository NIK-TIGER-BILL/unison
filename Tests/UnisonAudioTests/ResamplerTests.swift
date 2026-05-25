import Testing
@testable import UnisonAudio
@testable import UnisonDomain

@Test func resampler_downsampleAndConvert_48kF32_to_24kI16() {
    let input = makeFrame(pcm: fixture("sine-440hz-48k-f32-1sec"), rate: 48_000, format: .float32)
    let out = Resampler.toOpenAIWire(input)
    #expect(out.sampleRate == 24_000)
    #expect(out.format == .int16)
    #expect(out.channels == 1)
    #expect(out.pcm.count == 48_000)
}

@Test func resampler_upsampleAndConvert_24kI16_to_48kF32() {
    let input = makeFrame(pcm: fixture("sine-440hz-24k-int16-1sec"), rate: 24_000, format: .int16)
    let out = Resampler.fromOpenAIWire(input, targetSampleRate: 48_000)
    #expect(out.sampleRate == 48_000)
    #expect(out.format == .float32)
    #expect(out.channels == 1)
    #expect(out.pcm.count == 192_000)
}

@Test func resampler_passthroughWhenAlreadyMatching() {
    let input = makeFrame(pcm: fixture("sine-440hz-24k-int16-1sec"), rate: 24_000, format: .int16)
    let out = Resampler.toOpenAIWire(input)
    #expect(out == input)
}

@Test func resampler_roundTripPreservesEnergy() {
    let original = makeFrame(pcm: fixture("sine-440hz-48k-f32-1sec"), rate: 48_000, format: .float32)
    let wire = Resampler.toOpenAIWire(original)
    let back = Resampler.fromOpenAIWire(wire, targetSampleRate: 48_000)
    #expect(back.sampleRate == 48_000)
    #expect(back.format == .float32)
    #expect(abs(back.sampleCount - original.sampleCount) <= 1)
}
