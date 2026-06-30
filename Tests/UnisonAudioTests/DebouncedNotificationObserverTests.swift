import Testing
import Foundation
import AVFoundation
@testable import UnisonAudio

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// A burst of notifications (what a single device switch actually produces —
// device-removed, default-changed, format-settled) must collapse into ONE
// action, not one per notification.
@Test func debouncedObserver_coalescesBurstIntoSingleAction() async {
    let engine = AVAudioEngine()
    let counter = Counter()
    let obs = DebouncedNotificationObserver(name: .AVAudioEngineConfigurationChange,
                                            object: engine, debounceMilliseconds: 80) {
        counter.bump()
    }
    obs.start()
    for _ in 0..<5 {
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    }
    try? await Task.sleep(for: .milliseconds(300))
    #expect(counter.value == 1)
    obs.stop()
}

// stop() must cancel a pending (debounced) action — tearing the session down
// right after a device blip shouldn't then resurrect the engine.
@Test func debouncedObserver_stopCancelsPendingAction() async {
    let engine = AVAudioEngine()
    let counter = Counter()
    let obs = DebouncedNotificationObserver(name: .AVAudioEngineConfigurationChange,
                                            object: engine, debounceMilliseconds: 150) {
        counter.bump()
    }
    obs.start()
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
    obs.stop()
    try? await Task.sleep(for: .milliseconds(300))
    #expect(counter.value == 0)
}

// The observer is scoped to its own object — another object's notification of
// the same name must not trigger our action.
@Test func debouncedObserver_ignoresOtherObjectsNotifications() async {
    let engine = AVAudioEngine()
    let other = AVAudioEngine()
    let counter = Counter()
    let obs = DebouncedNotificationObserver(name: .AVAudioEngineConfigurationChange,
                                            object: engine, debounceMilliseconds: 80) {
        counter.bump()
    }
    obs.start()
    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: other)
    try? await Task.sleep(for: .milliseconds(250))
    #expect(counter.value == 0)
    obs.stop()
}
