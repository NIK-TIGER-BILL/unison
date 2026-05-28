import Foundation
import UnisonDomain

// MARK: - CLI

struct CLIArgs {
    let audioPath: String
    let targetLang: Language
    let outputDir: URL
    let label: String
    let runs: Int

    static func parse() throws -> CLIArgs {
        let args = CommandLine.arguments
        var audio: String?
        var target: String = "en"
        var output: String = "./pacing-eval-out"
        var label: String?
        var runs: Int = 1
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--audio":
                i += 1; audio = args[i]
            case "--target":
                i += 1; target = args[i]
            case "--output", "--out":
                i += 1; output = args[i]
            case "--label":
                i += 1; label = args[i]
            case "--runs":
                i += 1; runs = Int(args[i]) ?? 1
            case "--help", "-h":
                printHelp()
                exit(0)
            default:
                FileHandle.standardError.write("Unknown arg: \(args[i])\n".data(using: .utf8)!)
                printHelp()
                exit(2)
            }
            i += 1
        }
        guard let audio else {
            FileHandle.standardError.write("--audio <path> is required\n".data(using: .utf8)!)
            printHelp()
            exit(2)
        }
        guard let lang = Language(rawValue: target) else {
            FileHandle.standardError.write("--target must be a valid ISO 639-1 code (en, ru, es, ...). Got: \(target)\n".data(using: .utf8)!)
            exit(2)
        }
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let finalLabel = label ?? (audio as NSString).lastPathComponent.replacingOccurrences(of: ".", with: "_")
        return CLIArgs(audioPath: audio, targetLang: lang, outputDir: outputURL, label: finalLabel, runs: max(1, runs))
    }

    static func printHelp() {
        print("""
        pacing-eval — measure gpt-realtime-translate output cadence and
        replay the PlaybackPacing controller against the recorded timeline.

        Usage:
          pacing-eval --audio <path.wav> --target <lang> [--output <dir>] [--label <name>]

        Required:
          --audio <path>     Input audio file (WAV/AIFF/M4A; any sample rate)
          --target <code>    ISO 639-1 target language code (en, ru, es, de, fr, ...)

        Optional:
          --output <dir>     Output directory for CSVs + report (default: ./pacing-eval-out)
          --label <name>     Label prefix for output files (default: derived from audio filename)
          -h, --help         Show this help

        Env:
          OPENAI_API_KEY     Required; the bearer token for the Realtime API
        """)
    }
}

// MARK: - main

@main
struct PacingEvalCLI {
    static func main() async {
        do {
            let args = try CLIArgs.parse()
            guard let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty else {
                throw PacingEvalError.missingApiKey
            }

            print("[pacing-eval] audio=\(args.audioPath) target=\(args.targetLang.rawValue) out=\(args.outputDir.path) runs=\(args.runs)")

            let reader = AudioReader(url: URL(fileURLWithPath: args.audioPath), chunkMs: 100)
            let decoded = try reader.decode()
            print(String(format: "[pacing-eval] decoded %.2fs audio (%d chunks of %dms)",
                         decoded.totalDurationSec,
                         decoded.chunkCount,
                         100))

            let writer = ReportWriter(outputDir: args.outputDir)
            var allRuns: [AggregateAcrossRuns.RunSummary] = []

            for runIndex in 1...args.runs {
                print("\n========== run \(runIndex) / \(args.runs) ==========")
                let chunks = AudioChunkIterator(decoded: decoded)
                let session = Session(
                    apiKey: apiKey,
                    targetLang: args.targetLang,
                    chunks: chunks,
                    chunkInterval: 0.1,
                    drainTimeoutSec: 5.0
                )
                let result = try await session.run()
                print(String(format: "[pacing-eval] received %d output deltas over %.2fs wall-clock",
                             result.arrivals.count,
                             result.totalElapsedSec))

                let arrivalReport = ArrivalReport.compute(
                    arrivals: result.arrivals,
                    inputDurationSec: result.inputDurationSec
                )
                let runLabel = "\(args.label)-run\(runIndex)"
                try writer.writeArrivalsCSV(arrivals: result.arrivals, filename: "\(runLabel)-arrivals.csv")

                // Per-run: sweep pre-roll variants against the SAME
                // recorded arrival timeline so we can compare them
                // apples-to-apples (same model behaviour, different
                // pacing decisions).
                let variants: [(name: String, preroll: Double, fixed: Double?)] = [
                    ("v3-adaptive",     0.0, nil),
                    ("fixed-1.0",       0.0, 1.0),
                    ("fixed-1.0-pre200", 0.2, 1.0),
                    ("fixed-1.0-pre500", 0.5, 1.0)
                ]
                for v in variants {
                    var sim = PacingSimulator(arrivals: result.arrivals)
                    sim.prerollSec = v.preroll
                    sim.rateOverride = v.fixed
                    sim.variantLabel = v.name
                    let (rows, summary) = sim.simulate()
                    try writer.writeTickCSV(rows: rows, filename: "\(runLabel)-\(v.name)-ticks.csv")
                    writer.printSummary(label: "\(runLabel) | \(v.name)",
                                        arrival: arrivalReport,
                                        sim: summary)
                    // Only push the baseline (v3) variant into the
                    // cross-run aggregate so the summary represents
                    // production-equivalent behaviour.
                    if v.name == "v3-adaptive" {
                        allRuns.append(AggregateAcrossRuns.RunSummary(
                            runIndex: runIndex,
                            arrival: arrivalReport,
                            sim: summary
                        ))
                    }
                }

                // Brief cool-down between runs so we don't slam the API.
                if runIndex < args.runs {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            // Aggregate variability — tells us model vs network behaviour.
            AggregateAcrossRuns(label: args.label, runs: allRuns).printReport()
            print("[pacing-eval] CSVs written to \(args.outputDir.path)")
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
