public protocol PeerAudioCapture: Sendable {
    /// Reads from BlackHole 16ch (fixed device).
    func start() -> AsyncStream<AudioFrame>
    func stop()
}
