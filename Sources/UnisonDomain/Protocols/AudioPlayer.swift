public protocol AudioPlayer: Sendable {
    /// Writes frames to a fixed device (e.g., BlackHole 2ch).
    func play(_ frames: AsyncStream<AudioFrame>) async
    func stop()
}
