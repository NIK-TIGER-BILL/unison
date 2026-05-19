import Foundation
@testable import UnisonDomain

public final class MockAudioDeviceRegistry: AudioDeviceRegistry, @unchecked Sendable {
    public var inputs: [AudioDevice] = []
    public var outputs: [AudioDevice] = []
    public var bh2ch: AudioDevice?
    public var bh16ch: AudioDevice?
    private var changesContinuation: AsyncStream<Void>.Continuation?
    public let deviceChanges: AsyncStream<Void>

    public init() {
        var c: AsyncStream<Void>.Continuation!
        deviceChanges = AsyncStream { c = $0 }
        changesContinuation = c
    }
    public func availableInputDevices() -> [AudioDevice] { inputs }
    public func availableOutputDevices() -> [AudioDevice] { outputs }
    public func findBlackHole2ch() -> AudioDevice? { bh2ch }
    public func findBlackHole16ch() -> AudioDevice? { bh16ch }
    public func notifyDeviceChange() { changesContinuation?.yield() }
}
