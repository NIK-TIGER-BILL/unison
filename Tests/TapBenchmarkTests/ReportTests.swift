import Testing
import Foundation
@testable import TapBenchmark

private func sampleMetrics(median: Double, p95: Double = 0, jitter: Double = 0,
                           drop: Double = 0, cpu: Double = 0) -> PhaseMetrics {
    PhaseMetrics(
        medianLatencyMs: median, p95LatencyMs: p95, jitterStdDevMs: jitter,
        dropRate: drop, meanCpuPct: cpu
    )
}

@Test func renderText_bothPhasesPopulated_includesBothColumns() {
    let report = BenchmarkReport(
        timestampISO: "2026-05-27T10:30:00Z",
        durationSeconds: 30,
        clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch",
                               metrics: sampleMetrics(median: 12.3, p95: 18.1),
                               skipReason: nil),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 8.5, p95: 11.2),
                         skipReason: nil),
        setupFriendly: .skipped,
        blackHolePresent: true,
        isVM: true
    )
    let text = report.renderText()
    #expect(text.contains("BlackHole 16ch"))
    #expect(text.contains("Process Tap"))
    #expect(text.contains("12.3"))
    #expect(text.contains("8.5"))
    #expect(text.contains("SKIPPED"))
}

@Test func renderText_skippedBlackHole_showsSkipReason() {
    let report = BenchmarkReport(
        timestampISO: "2026-05-27T10:30:00Z",
        durationSeconds: 30, clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch", metrics: nil,
                               skipReason: "BlackHole 16ch not installed"),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 8.5),
                         skipReason: nil),
        setupFriendly: .pass,
        blackHolePresent: false,
        isVM: true
    )
    let text = report.renderText()
    #expect(text.contains("skipped"))
    #expect(text.contains("BlackHole 16ch not installed"))
    #expect(text.contains("PASS"))
}

@Test func verdict_tapFaster() {
    let report = BenchmarkReport(
        timestampISO: "", durationSeconds: 30, clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch",
                               metrics: sampleMetrics(median: 20, cpu: 5),
                               skipReason: nil),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 12, cpu: 6),
                         skipReason: nil),
        setupFriendly: .skipped, blackHolePresent: true, isVM: false
    )
    let text = report.renderText()
    #expect(text.contains("Process Tap is 8.0 ms faster"))
}

@Test func renderJSON_roundTripsMetrics() throws {
    let report = BenchmarkReport(
        timestampISO: "2026-05-27T10:30:00Z",
        durationSeconds: 30, clickCount: 150,
        blackhole: PhaseResult(name: "BlackHole 16ch",
                               metrics: sampleMetrics(median: 12.3, p95: 18.1,
                                                       jitter: 2.1, drop: 0.01, cpu: 4.5),
                               skipReason: nil),
        tap: PhaseResult(name: "Process Tap",
                         metrics: sampleMetrics(median: 8.5, p95: 11.2,
                                                jitter: 1.3, drop: 0, cpu: 5.0),
                         skipReason: nil),
        setupFriendly: .pass, blackHolePresent: false, isVM: true
    )
    let data = try report.renderJSON()
    let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: data)
    #expect(decoded.blackhole.metrics?.medianLatencyMs == 12.3)
    #expect(decoded.tap.metrics?.medianLatencyMs == 8.5)
    #expect(decoded.setupFriendly == .pass)
    #expect(decoded.isVM == true)
}
