import Foundation

public enum SetupFriendlyResult: String, Codable, Sendable {
    case pass = "PASS"
    case fail = "FAIL"
    case skipped = "SKIPPED"
}

public struct PhaseResult: Codable, Sendable {
    public let name: String
    public let metrics: PhaseMetrics?
    public let skipReason: String?

    public init(name: String, metrics: PhaseMetrics?, skipReason: String?) {
        self.name = name
        self.metrics = metrics
        self.skipReason = skipReason
    }
}

public struct BenchmarkReport: Codable, Sendable {
    public let timestampISO: String
    public let durationSeconds: Int
    public let clickCount: Int
    public let blackhole: PhaseResult
    public let tap: PhaseResult
    public let setupFriendly: SetupFriendlyResult
    public let blackHolePresent: Bool
    public let isVM: Bool

    public init(
        timestampISO: String,
        durationSeconds: Int,
        clickCount: Int,
        blackhole: PhaseResult,
        tap: PhaseResult,
        setupFriendly: SetupFriendlyResult,
        blackHolePresent: Bool,
        isVM: Bool
    ) {
        self.timestampISO = timestampISO
        self.durationSeconds = durationSeconds
        self.clickCount = clickCount
        self.blackhole = blackhole
        self.tap = tap
        self.setupFriendly = setupFriendly
        self.blackHolePresent = blackHolePresent
        self.isVM = isVM
    }

    public func renderText() -> String {
        var lines: [String] = []
        lines.append("Tap vs BlackHole capture benchmark")
        lines.append("duration: \(durationSeconds)s  •  clicks: \(clickCount)  •  signal: 2ms burst @ 200ms")
        lines.append("")

        let col1 = "                 "
        let col2 = "BlackHole 16ch   "
        let col3 = "Process Tap"
        lines.append("\(col1)\(col2)\(col3)")
        lines.append(String(repeating: "─", count: 50))

        func row(_ label: String, _ bhValue: String, _ tapValue: String) -> String {
            let lhs = label.padding(toLength: 17, withPad: " ", startingAt: 0)
            let mid = bhValue.padding(toLength: 17, withPad: " ", startingAt: 0)
            return "\(lhs)\(mid)\(tapValue)"
        }

        func fmt(_ m: PhaseMetrics?, _ keyPath: KeyPath<PhaseMetrics, Double>,
                 unit: String) -> String {
            guard let m = m else { return "skipped" }
            return String(format: "%.1f %@", m[keyPath: keyPath], unit)
        }

        lines.append(row("median latency",
            fmt(blackhole.metrics, \.medianLatencyMs, unit: "ms"),
            fmt(tap.metrics, \.medianLatencyMs, unit: "ms")))
        lines.append(row("p95 latency",
            fmt(blackhole.metrics, \.p95LatencyMs, unit: "ms"),
            fmt(tap.metrics, \.p95LatencyMs, unit: "ms")))
        lines.append(row("jitter (stddev)",
            fmt(blackhole.metrics, \.jitterStdDevMs, unit: "ms"),
            fmt(tap.metrics, \.jitterStdDevMs, unit: "ms")))
        lines.append(row("drop rate",
            blackhole.metrics.map { String(format: "%.1f %%", $0.dropRate * 100) } ?? "skipped",
            tap.metrics.map { String(format: "%.1f %%", $0.dropRate * 100) } ?? "skipped"))
        lines.append(row("mean CPU",
            blackhole.metrics.map { String(format: "%.1f %%", $0.meanCpuPct) } ?? "skipped",
            tap.metrics.map { String(format: "%.1f %%", $0.meanCpuPct) } ?? "skipped"))
        lines.append(String(repeating: "─", count: 50))

        if let bh = blackhole.metrics, let tp = tap.metrics {
            let delta = bh.medianLatencyMs - tp.medianLatencyMs
            let dir = delta >= 0 ? "faster" : "slower"
            let cpuDelta = tp.meanCpuPct - bh.meanCpuPct
            let cpuDir = cpuDelta >= 0 ? "more" : "less"
            lines.append(String(format:
                "verdict: Process Tap is %.1f ms %@ (median), %.1f%% %@ CPU",
                abs(delta), dir, abs(cpuDelta), cpuDir))
        } else {
            lines.append("verdict: (incomplete — one phase skipped)")
            if let reason = blackhole.skipReason {
                lines.append("        BlackHole skipped: \(reason)")
            }
            if let reason = tap.skipReason {
                lines.append("        Tap skipped: \(reason)")
            }
        }

        lines.append("")
        lines.append("Setup-friendly check: \(setupFriendly.rawValue)")
        return lines.joined(separator: "\n")
    }

    public func renderJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
