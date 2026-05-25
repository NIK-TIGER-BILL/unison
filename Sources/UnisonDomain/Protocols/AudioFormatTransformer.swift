import Foundation

public protocol AudioFormatTransformer: Sendable {
    /// Capture format (e.g. 48kHz F32) → wire format (24kHz Int16) for OpenAI.
    func toWire(_ frame: AudioFrame) -> AudioFrame

    /// Wire format (24kHz Int16) → playback format (e.g. 48kHz F32) for AVAudioEngine.
    func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame
}
