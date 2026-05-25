import Foundation
@testable import UnisonDomain

public final class MockPeerAudioCapture: PeerAudioCapture, @unchecked Sendable {
    public var startCalls = 0
    public var stopCalls = 0
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    public init() {}
    public func start() -> AsyncStream<AudioFrame> {
        startCalls += 1
        return AsyncStream { c in self.continuation = c }
    }
    public func stop() { stopCalls += 1; continuation?.finish() }
    public func emit(_ frame: AudioFrame) { continuation?.yield(frame) }
}
