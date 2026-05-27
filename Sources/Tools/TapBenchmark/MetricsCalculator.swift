import Foundation

public struct PhaseMetrics: Sendable, Equatable {
    public let medianLatencyMs: Double
    public let p95LatencyMs: Double
    public let jitterStdDevMs: Double
    public let dropRate: Double
    public let meanCpuPct: Double

    public init(
        medianLatencyMs: Double,
        p95LatencyMs: Double,
        jitterStdDevMs: Double,
        dropRate: Double,
        meanCpuPct: Double
    ) {
        self.medianLatencyMs = medianLatencyMs
        self.p95LatencyMs = p95LatencyMs
        self.jitterStdDevMs = jitterStdDevMs
        self.dropRate = dropRate
        self.meanCpuPct = meanCpuPct
    }
}

public enum MetricsCalculator {
    public static func compute(
        expectedClickTimes: [UInt64],
        detectedClickTimes: [UInt64],
        matchWindowMs: Double,
        cpuSamples: [Double]
    ) -> PhaseMetrics {
        var latencies: [Double] = []
        var matched = 0

        for expected in expectedClickTimes {
            var bestDelta: Double?
            for detected in detectedClickTimes {
                let delta = HostTimeClock.milliseconds(from: expected, to: detected)
                guard abs(delta) <= matchWindowMs else { continue }
                if bestDelta == nil || abs(delta) < abs(bestDelta!) {
                    bestDelta = delta
                }
            }
            if let d = bestDelta {
                latencies.append(d)
                matched += 1
            }
        }

        let sorted = latencies.sorted()
        let median: Double
        if sorted.isEmpty {
            median = 0
        } else if sorted.count % 2 == 0 {
            let mid = sorted.count / 2
            median = (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }

        let p95Idx = Int(Double(sorted.count) * 0.95)
        let p95 = sorted.isEmpty ? 0 : sorted[min(p95Idx, sorted.count - 1)]

        let mean = latencies.isEmpty
            ? 0
            : latencies.reduce(0, +) / Double(latencies.count)
        let variance = latencies.isEmpty
            ? 0
            : latencies.map { pow($0 - mean, 2) }.reduce(0, +) / Double(latencies.count)
        let stddev = sqrt(variance)

        let dropRate = expectedClickTimes.isEmpty
            ? 0
            : Double(expectedClickTimes.count - matched) / Double(expectedClickTimes.count)

        let cpuMean = cpuSamples.isEmpty
            ? 0
            : cpuSamples.reduce(0, +) / Double(cpuSamples.count)

        return PhaseMetrics(
            medianLatencyMs: median,
            p95LatencyMs: p95,
            jitterStdDevMs: stddev,
            dropRate: dropRate,
            meanCpuPct: cpuMean
        )
    }
}
