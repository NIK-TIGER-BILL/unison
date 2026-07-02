public protocol AudioOutputMixer: Sendable {
    func start(deviceUID: String?) async throws
    func playTranslated(_ frames: AsyncStream<AudioFrame>) async
    func playOriginal(_ frames: AsyncStream<AudioFrame>) async
    func setOriginalGain(_ gain: Float)
    func stop()

    /// Emits after each (re)configuration of the output engine with the
    /// negotiated route's quality: `true` when the route is narrowband —
    /// i.e. the device is running a Bluetooth VOICE profile (HFP), which
    /// macOS forces on a headset whenever something opens its mic. The
    /// orchestrator publishes the latest value as `outputRouteDegraded`
    /// so the UI can explain the "muffled, behind-a-wall" sound instead
    /// of leaving the user to blame the translation. One long-lived
    /// stream per mixer instance; the orchestrator subscribes once.
    var routeDegradedEvents: AsyncStream<Bool> { get }
}

public extension AudioOutputMixer {
    /// Default: no route-quality reporting (mocks, harness players). A
    /// fresh finished stream per access — a subscriber's `for await`
    /// completes immediately.
    var routeDegradedEvents: AsyncStream<Bool> {
        AsyncStream { $0.finish() }
    }
}
