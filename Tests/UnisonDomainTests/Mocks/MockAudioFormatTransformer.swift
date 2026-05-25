import Foundation
@testable import UnisonDomain

public final class MockAudioFormatTransformer: AudioFormatTransformer, @unchecked Sendable {
    public init() {}
    public func toWire(_ frame: AudioFrame) -> AudioFrame {
        // Identity transform for tests — preserves format flag changes that real Resampler would do
        AudioFrame(pcm: frame.pcm, sampleRate: 24_000, channels: frame.channels, format: .int16)
    }
    public func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        AudioFrame(pcm: frame.pcm, sampleRate: targetSampleRate, channels: frame.channels, format: .float32)
    }
}
