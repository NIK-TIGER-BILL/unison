import Testing
@testable import UnisonDomain

@Test func fakeClock_advancesNowByAdvanceCall() {
    let start = epochDate(0)
    let clock = FakeClock(now: start)
    #expect(clock.now() == start)
    clock.advance(by: 5)
    #expect(clock.now() == start.addingTimeInterval(5))
}

@Test func fakeClock_sleepResumesAfterAdvance() async throws {
    let clock = FakeClock(now: epochDate(0))
    let task = Task {
        try await clock.sleep(for: 10)
        return clock.now()
    }
    try await Task.sleep(nanoseconds: 50_000_000)
    clock.advance(by: 10)
    let result = try await task.value
    #expect(result.timeIntervalSince1970 == 10)
}
