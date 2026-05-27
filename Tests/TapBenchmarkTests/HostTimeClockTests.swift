import Testing
@testable import TapBenchmark

@Test func now_isMonotonicallyIncreasing() {
    let a = HostTimeClock.now()
    let b = HostTimeClock.now()
    #expect(b >= a)
}

@Test func nanoseconds_zeroTicksIsZero() {
    #expect(HostTimeClock.nanoseconds(fromTicks: 0) == 0)
}

@Test func nanoseconds_oneSecondOfTicksIsBillion() {
    let oneSecondTicks = HostTimeClock.ticks(forMilliseconds: 1000)
    let ns = HostTimeClock.nanoseconds(fromTicks: oneSecondTicks)
    #expect(abs(Int64(ns) - 1_000_000_000) < 100)
}

@Test func milliseconds_betweenEqualTicksIsZero() {
    let t = HostTimeClock.now()
    #expect(HostTimeClock.milliseconds(from: t, to: t) == 0)
}

@Test func milliseconds_signedDifference() {
    let a = HostTimeClock.now()
    let b = a + HostTimeClock.ticks(forMilliseconds: 50)
    #expect(abs(HostTimeClock.milliseconds(from: a, to: b) - 50.0) < 0.001)
    #expect(abs(HostTimeClock.milliseconds(from: b, to: a) - (-50.0)) < 0.001)
}

@Test func ticks_forMilliseconds_roundTrip() {
    let t = HostTimeClock.ticks(forMilliseconds: 123.456)
    let ms = HostTimeClock.milliseconds(from: 0, to: t)
    #expect(abs(ms - 123.456) < 0.001)
}
