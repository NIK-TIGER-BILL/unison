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
        print(String(format: "Underrun ticks       : %d / %d (%.1f%%)",
                     sim.underrunTicks, sim.totalTicks, sim.underrunPercent))
        print(String(format: "Depth mean           : %.3fs (min %.3f, max %.3f)",
                     sim.depthMeanWhenSpeaking, sim.depthMin, sim.depthMax))
        print(String(format: "Applied rate mean    : %.3f (min %.3f, max %.3f)",
                     sim.rateMean, sim.rateMin, sim.rateMax))
        print(String(format: "Arrival EMA mean     : %.3f", sim.arrivalRateMean))
        print("")
    }
}
