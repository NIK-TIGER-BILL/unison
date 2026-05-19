import Foundation
import UnisonDomain

public struct ResamplerAdapter: AudioFormatTransformer {
    public init() {}
    public func toWire(_ frame: AudioFrame) -> AudioFrame {
        Resampler.toOpenAIWire(frame)
    }
    public func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        Resampler.fromOpenAIWire(frame, targetSampleRate: targetSampleRate)
    }
}
