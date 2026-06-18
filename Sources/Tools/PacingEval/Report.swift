import Foundation

/// Summarises the model-side timing of one session: when did deltas
/// arrive, how big were they, what's the implied long-run arrival rate.
struct ArrivalReport {
    let inputDurationSec: Double
    let outputAudioSec: Double
    let firstArrivalSec: Double?
    let lastArrivalSec: Double?
    let arrivalCount: Int
    /// Long-run output_rate = sum(audio_durations) / wall_clock_elapsed.
    /// > 1.0 means model emits faster than real-time on average; this
    /// is what causes the production buffer to grow.
    let arrivalRateRatio: Double
    /// Inter-arrival gap percentiles (seconds). Tells us how bursty
    /// the model's output is — large p95 means we get bursts followed
    /// by long pauses.
    let gapP50Sec: Double
    let gapP95Sec: Double
    let gapP99Sec: Double
    let gapMaxSec: Double

    static func compute(arrivals: [ArrivalRecord], inputDurationSec: Double) -> ArrivalReport {
        let outputAudio = arrivals.reduce(0.0) { $0 + $1.audioDurationSec }
        let firstT = arrivals.first?.t
        let lastT = arrivals.last?.t
        let elapsed = (lastT ?? 0) - (firstT ?? 0)
        let rate = elapsed > 0 ? outputAudio / elapsed : 0
        let gaps = zip(arrivals.dropFirst(), arrivals).map { $0.t - $1.t }
        let sorted = gaps.sorted()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let i = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
            return sorted[i]
        }
        return ArrivalReport(
            inputDurationSec: inputDurationSec,
            outputAudioSec: outputAudio,
            firstArrivalSec: firstT,
            lastArrivalSec: lastT,
            arrivalCount: arrivals.count,
            arrivalRateRatio: rate,
            gapP50Sec: pct(0.50),
            gapP95Sec: pct(0.95),
            gapP99Sec: pct(0.99),
            gapMaxSec: sorted.last ?? 0
        )
    }
}

/// Writes the per-tick simulation rows to a CSV file for plotting,
/// and prints a human-friendly summary to stdout.
struct ReportWriter {
    let outputDir: URL

    func writeTickCSV(rows: [PacingSimulator.TickRow], filename: String) throws {
        let path = outputDir.appendingPathComponent(filename)
        var csv = "t_sec,depth_sec,depth_smooth_sec,arrival_ema,consumption_ema,applied_rate,target_rate,buffer_error,underrun\n"
        for r in rows {
            csv += String(
                format: "%.3f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d\n",
                r.t, r.depth, r.depthSmooth, r.arrivalRateEMA, r.consumptionRateEMA,
                r.appliedRate, r.targetRate, r.bufferError, r.underrun ? 1 : 0
            )
        }
        try csv.write(to: path, atomically: true, encoding: .utf8)
    }

    func writeArrivalsCSV(arrivals: [ArrivalRecord], filename: String) throws {
        let path = outputDir.appendingPathComponent(filename)
        var csv = "t_sec,bytes,audio_duration_sec\n"
        for a in arrivals {
            csv += String(format: "%.4f,%d,%.4f\n", a.t, a.bytes, a.audioDurationSec)
        }
        try csv.write(to: path, atomically: true, encoding: .utf8)
    }

    func printSummary(
        label: String,
        arrival: ArrivalReport,
        sim: PacingSimulator.Summary
    ) {
        print("\n=== \(label) ===")
        print(String(format: "Input duration       : %.2fs", arrival.inputDurationSec))
        print(String(format: "Output audio total   : %.2fs (ratio %.3f vs input)",
                     arrival.outputAudioSec,
                     arrival.inputDurationSec > 0 ? arrival.outputAudioSec / arrival.inputDurationSec : 0))
        if let t = arrival.firstArrivalSec {
            print(String(format: "First delta latency  : %.2fs after first input chunk", t))
        }
        if let last = arrival.lastArrivalSec {
            print(String(format: "Last delta at        : %.2fs (= %.2fs after last input)",
                         last, last - arrival.inputDurationSec))
        }
        print(String(format: "Arrival rate ratio   : %.3fx (output_audio / wall_clock between first & last delta)",
                     arrival.arrivalRateRatio))
        print(String(format: "Deltas               : %d", arrival.arrivalCount))
        print(String(format: "Inter-arrival p50    : %.3fs", arrival.gapP50Sec))
        print(String(format: "Inter-arrival p95    : %.3fs", arrival.gapP95Sec))
        print(String(format: "Inter-arrival p99    : %.3fs", arrival.gapP99Sec))
        print(String(format: "Inter-arrival max    : %.3fs", arrival.gapMaxSec))
        print("--- pacing simulation ---")
        print(String(format: "Underrun ticks       : %d / %d active (%.1f%%)",
                     sim.underrunTicks, sim.activeTicks, sim.underrunPercent))
        print(String(format: "Depth mean           : %.3fs (min %.3f, max %.3f)",
                     sim.depthMeanWhenSpeaking, sim.depthMin, sim.depthMax))
        print(String(format: "Applied rate mean    : %.3f (min %.3f, max %.3f)",
                     sim.rateMean, sim.rateMin, sim.rateMax))
        print(String(format: "Arrival EMA mean     : %.3f", sim.arrivalRateMean))
        // User-facing latency: when does the last audio sample leave
        // the player. This is what the user actually perceives — they
        // keep hearing translation until this moment.
        let perceivedLatencyPastInput = sim.playbackFinishedAtSec - arrival.inputDurationSec
        print(String(format: "Playback finished at : %.2fs", sim.playbackFinishedAtSec))
        print(String(format: "  ↳ past input end   : +%.2fs (this is the user-perceived tail)",
                     perceivedLatencyPastInput))
        print("")
    }
}

// MARK: - Cross-run aggregate

/// Collected per-run summaries for a single audio fixture. Used to tell
/// "the model behaves like this consistently" from "the network just
/// hiccuped once". Print after every fixture's runs complete.
struct AggregateAcrossRuns {
    struct RunSummary {
        let runIndex: Int
        let arrival: ArrivalReport
        let sim: PacingSimulator.Summary
    }
    let label: String
    let runs: [RunSummary]

    func printReport() {
        guard !runs.isEmpty else { return }
        print("\n===== AGGREGATE: \(label) across \(runs.count) runs =====")
        // Inter-run variability of the metrics that matter for UX.
        let underrunPercents = runs.map { $0.sim.underrunPercent }
        let maxGaps = runs.map { $0.arrival.gapMaxSec }
        let perceivedTails = runs.map { $0.sim.playbackFinishedAtSec - $0.arrival.inputDurationSec }
        let arrivalRates = runs.map { $0.arrival.arrivalRateRatio }
        let depthMaxes = runs.map { $0.sim.depthMax }
        printStat("Underrun %", underrunPercents, suffix: "%")
        printStat("Max gap", maxGaps, suffix: "s")
        printStat("Perceived tail (post-input)", perceivedTails, suffix: "s")
        printStat("Arrival rate", arrivalRates, suffix: "x")
        printStat("Depth max", depthMaxes, suffix: "s")
        // Per-run timeline of max gaps — shows whether the "big gap"
        // moves around (network) or sticks (model).
        print("Per-run max-gap timeline:")
        for r in runs {
            print(String(format: "  run %d: max gap %.2fs at last-arrival t=%.2fs",
                         r.runIndex, r.arrival.gapMaxSec, r.arrival.lastArrivalSec ?? 0))
        }
        print("")
    }

    private func printStat(_ name: String, _ values: [Double], suffix: String) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        let mn = sorted.first ?? 0
        let mx = sorted.last ?? 0
        // String.init(format:) does NOT support %s for Swift String
        // (it'd read garbage; segfaults inside strlen). Interpolate the
        // name + suffix into Swift's String first, then use %f-only
        // format strings.
        let padded = name.padding(toLength: 30, withPad: " ", startingAt: 0)
        let nums = String(format: "mean=%.2f  min=%.2f  max=%.2f",
                          mean, mn, mx)
        print("\(padded)\(nums)\(suffix.isEmpty ? "" : " (\(suffix))")")
    }
}
