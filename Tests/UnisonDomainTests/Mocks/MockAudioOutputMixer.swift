import Foundation
@testable import UnisonDomain

public final class MockAudioOutputMixer: AudioOutputMixer, @unchecked Sendable {
    public var startedWithUID: String??
    public var translatedTaskActive = false
    public var originalTaskActive = false
    public var currentGain: Float = 0.0

    /// `stop()` call count. Lock-guarded because the wedged-teardown tests
    /// read it from the main actor while `stop()` runs on a detached
    /// teardown thread with no synchronizing await between them.
    private let countLock = NSLock()
    private var _stopCalls = 0
    public var stopCalls: Int {
        countLock.lock(); defer { countLock.unlock() }
        return _stopCalls
    }

    /// When `true`, `stop()` blocks (after counting) until `releaseStop()`
    /// is called — a stand-in for the synchronous CoreAudio HAL teardown
    /// (`AVAudioEngine.stop()` / Process-Tap aggregate-device destroy)
    /// that intermittently wedges for a long time, especially on a
    /// Bluetooth output device. Lets a test prove the session still
    /// reaches `.idle`, and that overlapping teardowns serialize instead
    /// of double-calling `stop()` on the shared HAL objects.
    public var blockStopUntilReleased = false
    private let stopGate = DispatchSemaphore(value: 0)

    public init() {}
    public func start(deviceUID: String?) async throws { startedWithUID = .some(deviceUID) }
    public func playTranslated(_ frames: AsyncStream<AudioFrame>) async {
        translatedTaskActive = true
        for await _ in frames {}
        translatedTaskActive = false
    }
    public func playOriginal(_ frames: AsyncStream<AudioFrame>) async {
        originalTaskActive = true
        for await _ in frames {}
        originalTaskActive = false
    }
    public func setOriginalGain(_ gain: Float) { currentGain = gain }
    /// Last sink handed to `setEchoReference`. `.some(nil)` records an
    /// explicit clear; `.none` means it was never called.
    public var echoReference: (any EchoReferenceSink)??
    public func setEchoReference(_ sink: (any EchoReferenceSink)?) {
        echoReference = .some(sink)
    }
    public func stop() {
        countLock.lock(); _stopCalls += 1; countLock.unlock()
        guard blockStopUntilReleased else { return }
        // Self-healing 10s timeout so a test that forgets `releaseStop()`
        // can't wedge the whole suite the way the production bug wedged the
        // app. The turnstile re-signal means one `releaseStop()` cascades
        // through every blocked `stop()` in a chained/serialized teardown.
        _ = stopGate.wait(timeout: .now() + 10)
        stopGate.signal()
    }

    /// Unblock a `stop()` parked on `blockStopUntilReleased`. Turnstile —
    /// a single call frees an entire chain of serialized teardowns.
    public func releaseStop() { stopGate.signal() }
}
