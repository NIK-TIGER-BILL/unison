import Foundation

public protocol AudioFormatTransformer: Sendable {
    /// Capture format (e.g. 48kHz F32) → wire format (`sampleRate` Int16).
    func toWire(_ frame: AudioFrame, sampleRate: Int) -> AudioFrame

    /// Wire format → playback format (e.g. 48kHz F32) for AVAudioEngine.
    func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame

    /// A transformer instance dedicated to ONE live pipeline. Stateful
    /// implementations (the streaming resampler, which preserves converter
    /// filter state across chunks for seam-free audio) return a fresh
    /// instance so two concurrent pipelines converting the same rate pair
    /// (mic + peer) never share filter state. Stateless implementations
    /// (mocks, the one-shot adapter) just return `self` — the default.
    /// The orchestrator calls this once per `wire*Pipeline`.
    func makeStreamTransformer() -> any AudioFormatTransformer
}

public extension AudioFormatTransformer {
    func makeStreamTransformer() -> any AudioFormatTransformer { self }
}
