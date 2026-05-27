import Testing
@testable import TapBenchmark

@Test func allClicksMatched_zeroDrops() {
    let expected: [UInt64] = [
        0,
        HostTimeClock.ticks(forMilliseconds: 200),
        HostTimeClock.ticks(forMilliseconds: 400)
    ]
    let detected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 10),
        HostTimeClock.ticks(forMilliseconds: 210),
        HostTimeClock.ticks(forMilliseconds: 410)
    ]
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 100,
        cpuSamples: [10.0, 20.0, 15.0]
    )
    #expect(abs(m.medianLatencyMs - 10.0) < 0.01)
    #expect(abs(m.p95LatencyMs - 10.0) < 0.01)
    #expect(m.jitterStdDevMs < 0.01)
    #expect(m.dropRate == 0.0)
    #expect(abs(m.meanCpuPct - 15.0) < 0.01)
}

@Test func oneDroppedClick_reflectedInDropRate() {
    let expected: [UInt64] = [
        0,
        HostTimeClock.ticks(forMilliseconds: 200),
        HostTimeClock.ticks(forMilliseconds: 400)
    ]
    let detected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 10),
        HostTimeClock.ticks(forMilliseconds: 410)
    ]
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 100,
        cpuSamples: []
    )
    #expect(abs(m.dropRate - (1.0 / 3.0)) < 0.001)
    #expect(abs(m.medianLatencyMs - 10.0) < 0.01)
}

@Test func medianAndP95_withSpread() {
    let interval: Double = 200
    let latencies: [Double] = [5,6,7,8,9,10,11,12,13,100]
    var expected: [UInt64] = []
    var detected: [UInt64] = []
    for (i, latency) in latencies.enumerated() {
        let base = HostTimeClock.ticks(forMilliseconds: Double(i) * interval)
        expected.append(base)
        detected.append(base + HostTimeClock.ticks(forMilliseconds: latency))
    }
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 200,
        cpuSamples: []
    )
    #expect(abs(m.medianLatencyMs - 9.5) < 0.01)
    #expect(abs(m.p95LatencyMs - 100.0) < 0.01)
}

@Test func emptyCpuSamples_meanIsZero() {
    let m = MetricsCalculator.compute(
        expectedClickTimes: [],
        detectedClickTimes: [],
        matchWindowMs: 100,
        cpuSamples: []
    )
    #expect(m.meanCpuPct == 0.0)
}

@Test func extraDetections_ignored() {
    let expected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 1000),
        HostTimeClock.ticks(forMilliseconds: 2000)
    ]
    let detected: [UInt64] = [
        HostTimeClock.ticks(forMilliseconds: 100),
        HostTimeClock.ticks(forMilliseconds: 500),
        HostTimeClock.ticks(forMilliseconds: 1010),
        HostTimeClock.ticks(forMilliseconds: 1500),
        HostTimeClock.ticks(forMilliseconds: 2005)
    ]
    let m = MetricsCalculator.compute(
        expectedClickTimes: expected,
        detectedClickTimes: detected,
        matchWindowMs: 100,
        cpuSamples: []
    )
    #expect(m.dropRate == 0.0)
    #expect(abs(m.medianLatencyMs - 7.5) < 0.01)
}
