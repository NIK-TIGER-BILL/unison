import Testing
import Foundation
@testable import UnisonDomain

// Thread-safe flag used to check callback invocation across Sendable closure boundaries.
private final class Triggered: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.withLock { _value }
    }
    func set() {
        lock.withLock { _value = true }
    }
}

@Test func watchdog_silenceForFullThreshold_triggersError() async {
    let triggered = Triggered()
    let watchdog = SilentFrameWatchdog(thresholdSeconds: 0.05) {
        triggered.set()
    }
    watchdog.start()
    // Feed 100 ms of all-zero samples.
    let zeros = Data(repeating: 0, count: 4 * 1000)  // 1000 Float32 zeros
    for _ in 0..<10 {
        watchdog.observe(zeros)
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    watchdog.stop()
    #expect(triggered.value)
}

@Test func watchdog_nonZeroSampleResetsTimer() async {
    let triggered = Triggered()
    // 0.5 s threshold (vs ~0.05 s of real silence fed on each side of
    // the reset) — the watchdog measures wall-clock Date() between
    // observe() calls, and Task.sleep only overshoots; with the old
    // 0.1 s threshold a loaded parallel test run could legitimately
    // accumulate >0.1 s of real silence and trip a false failure.
    let watchdog = SilentFrameWatchdog(thresholdSeconds: 0.5) {
        triggered.set()
    }
    watchdog.start()
    let zeros = Data(repeating: 0, count: 4 * 100)
    var nonZero = Data(count: 4 * 100)
    nonZero.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Float.self).baseAddress!
        p[0] = 0.5
    }
    // 50 ms zeros, then a non-zero, then 50 ms zeros — should NOT trigger
    // because the non-zero resets the timer.
    for _ in 0..<5 { watchdog.observe(zeros); try? await Task.sleep(nanoseconds: 10_000_000) }
    watchdog.observe(nonZero)
    for _ in 0..<5 { watchdog.observe(zeros); try? await Task.sleep(nanoseconds: 10_000_000) }
    watchdog.stop()
    #expect(!triggered.value)
}

@Test func watchdog_stopPreventsCallback() async {
    let triggered = Triggered()
    let watchdog = SilentFrameWatchdog(thresholdSeconds: 0.05) {
        triggered.set()
    }
    watchdog.start()
    watchdog.stop()
    let zeros = Data(repeating: 0, count: 4 * 1000)
    watchdog.observe(zeros)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(!triggered.value)
}
