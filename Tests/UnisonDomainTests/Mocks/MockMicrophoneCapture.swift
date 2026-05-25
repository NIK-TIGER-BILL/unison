import Foundation
@testable import UnisonDomain

public final class MockMicrophoneCapture: MicrophoneCapture, @unchecked Sendable {
    public var startedWithUID: String??
    public var stopCalls = 0
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    public init() {}

    public func start(deviceUID: String?) -> AsyncStream<AudioFrame> {
        startedWithUID = .some(deviceUID)
        return AsyncStream { c in self.continuation = c }
    }
    public func stop() { stopCalls += 1; continuation?.finish() }
    public func emit(_ frame: AudioFrame) { continuation?.yield(frame) }
}
