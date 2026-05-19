public protocol AudioOutputMixer: Sendable {
    func start(deviceUID: String?) async throws
    func playTranslated(_ frames: AsyncStream<AudioFrame>) async
    func playOriginal(_ frames: AsyncStream<AudioFrame>) async
    func setOriginalGain(_ gain: Float)
    func stop()
}
