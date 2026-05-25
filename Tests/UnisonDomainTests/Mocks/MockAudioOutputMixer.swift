import Foundation
@testable import UnisonDomain

public final class MockAudioOutputMixer: AudioOutputMixer, @unchecked Sendable {
    public var startedWithUID: String??
    public var stopCalls = 0
    public var translatedTaskActive = false
    public var originalTaskActive = false
    public var currentGain: Float = 0.0

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
    public func stop() { stopCalls += 1 }
}
