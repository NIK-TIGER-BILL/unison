import Foundation
@testable import UnisonDomain

public final class MockMicrophoneCapture: MicrophoneCapture, @unchecked Sendable {
    public var startedWithUID: String??
    public var stopCalls = 0
    /// Records whether `stop()` ran on the main thread. The orchestrator
    /// must tear capture down OFF the main thread — blocking CoreAudio
    /// HAL teardown on the main actor froze the app on Stop.
    public nonisolated(unsafe) var stoppedOnMainThread: Bool?
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    public init() {}

    public func start(deviceUID: String?) -> AsyncStream<AudioFrame> {
        startedWithUID = .some(deviceUID)
        return AsyncStream { c in self.continuation = c }
    }
    public func stop() {
        stoppedOnMainThread = Thread.isMainThread
        stopCalls += 1
        continuation?.finish()
    }
    public func emit(_ frame: AudioFrame) { continuation?.yield(frame) }
}
