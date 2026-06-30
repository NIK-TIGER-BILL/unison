public protocol AudioOutputMixer: Sendable {
    func start(deviceUID: String?) async throws
    func playTranslated(_ frames: AsyncStream<AudioFrame>) async
    func playOriginal(_ frames: AsyncStream<AudioFrame>) async
    func setOriginalGain(_ gain: Float)
    /// Register (or clear with `nil`) the AEC far-end reference sink. The
    /// mixer forwards its rendered output to the sink while one is set.
    func setEchoReference(_ sink: (any EchoReferenceSink)?)
    func stop()
}
