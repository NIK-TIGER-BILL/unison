import Foundation

public protocol AudioFormatTransformer: Sendable {
    /// Capture format (e.g. 48kHz F32) → wire format (`sampleRate` Int16).
    func toWire(_ frame: AudioFrame, sampleRate: Int) -> AudioFrame

    /// Wire format → playback format (e.g. 48kHz F32) for AVAudioEngine.
    func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame
}
