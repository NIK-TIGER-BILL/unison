public protocol PeerAudioCapture: Sendable {
    /// Starts audio capture and returns frames via `AsyncStream`.
    func start() -> AsyncStream<AudioFrame>
    func stop()
}
