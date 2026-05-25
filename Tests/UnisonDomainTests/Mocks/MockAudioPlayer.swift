import Foundation
@testable import UnisonDomain

public final class MockAudioPlayer: AudioPlayer, @unchecked Sendable {
    public var playTaskActive = false
    public var stopCalls = 0

    public init() {}
    public func play(_ frames: AsyncStream<AudioFrame>) async {
        playTaskActive = true
        for await _ in frames {}
        playTaskActive = false
    }
    public func stop() { stopCalls += 1 }
}
