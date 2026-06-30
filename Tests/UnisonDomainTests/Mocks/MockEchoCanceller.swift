import Foundation
@testable import UnisonDomain

public final class MockEchoCanceller: EchoCanceller, @unchecked Sendable {
    public private(set) var processNearCalls = 0
    public private(set) var resetCalls = 0
    public private(set) var farPushes = 0
    private let lock = NSLock()

    public init() {}

    public func pushFarReference(_ frame: AudioFrame) {
        lock.lock(); farPushes += 1; lock.unlock()
    }
    public func processNear(_ frame: AudioFrame) -> AudioFrame {
        lock.lock(); processNearCalls += 1; lock.unlock()
        return frame   // passthrough; we only assert it was invoked
    }
    public func reset() {
        lock.lock(); resetCalls += 1; lock.unlock()
    }
    public var processNearCount: Int { lock.lock(); defer { lock.unlock() }; return processNearCalls }
}
