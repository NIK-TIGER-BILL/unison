import Foundation
import AVFoundation
import UnisonDomain

// MARK: - CLI

struct CLIArgs {
    let audioPath: String
    let targetLang: Language
    let outputDir: URL
    let label: String
    let runs: Int
    /// Which translation provider to target. Default `.openAIRealtime`.
    let provider: TranslationModel
    /// When set, skip the OpenAI session entirely and just render the
    /// input audio through our production AVAudioEngine playback chain
    /// (player → timePitch → mixer) offline. Used to test whether the
    /// fade-out the user reports is introduced by our nodes.
    let playbackTestOnly: Bool

    static func parse() throws -> CLIArgs {
        let args = CommandLine.arguments
        var audio: String?
        var target: String = "en"
        var output: String = "./pacing-eval-out"
        var label: String?
        var runs: Int = 1
        var provider: TranslationModel = .openAIRealtime
        var playbackTestOnly = false
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
            case "--provider":
                i += 1
                switch args[i] {
                case "openai":
                    provider = .openAIRealtime
                case "gemini":
                    provider = .geminiLiveTranslate
                default:
                    FileHandle.standardError.write(
                        "--provider must be 'openai' or 'gemini'. Got: \(args[i])\n".data(using: .utf8)!
                    )
                    exit(2)
                }
            case "--playback-test":
                playbackTestOnly = true
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
        return CLIArgs(
            audioPath: audio,
            targetLang: lang,
            outputDir: outputURL,
            label: finalLabel,
            runs: max(1, runs),
            provider: provider,
            playbackTestOnly: playbackTestOnly
        )
    }

    static func printHelp() {
        print("""
        pacing-eval — measure realtime-translate output cadence and
        replay the PlaybackPacing controller against the recorded timeline.

        Usage:
          pacing-eval --audio <path.wav> --target <lang> [--provider <name>] [--output <dir>] [--label <name>]

        Required:
          --audio <path>       Input audio file (WAV/AIFF/M4A; any sample rate)
          --target <code>      ISO 639-1 target language code (en, ru, es, de, fr, ...)

        Optional:
          --provider <name>    Translation provider: openai (default) or gemini
          --output <dir>       Output directory for CSVs + report (default: ./pacing-eval-out)
          --label <name>       Label prefix for output files (default: derived from audio filename)
          -h, --help           Show this help

        Env:
          OPENAI_API_KEY       Required for --provider openai (default)
          GEMINI_API_KEY       Required for --provider gemini
        """)
    }
}

// MARK: - Playback-only test

/// Renders the input WAV through our production AVAudioEngine chain
/// (player → timePitch → mainMixer) offline and compares input vs
/// output RMS per second. Used to test whether the fade-out reported
/// by the user is introduced by our playback nodes themselves
/// (independent of OpenAI, network, audio devices).
func runPlaybackTest(decoded: AudioReader.Decoded, args: CLIArgs) throws {
    print("[playback-test] rendering \(String(format: "%.2fs", decoded.totalDurationSec)) through production playback chain (offline)")

    // Add a couple seconds of render-tail so the post-input drain
    // completes inside the offline window.
    let renderDur = decoded.totalDurationSec + 2.0
    for useTimePitch in [true, false] {
        let label = useTimePitch ? "with-timepitch" : "no-timepitch"
        let renderer = PlaybackOfflineRender(
            inputPCM24kInt16: decoded.pcm,
            renderDurationSec: renderDur,
            useTimePitch: useTimePitch
        )
        let out = try renderer.render()
        print("[playback-test] \(label): \(out.renderedFrames) frames rendered (\(String(format: "%.2fs", Double(out.renderedFrames) / 48_000.0)))")

        // Build ArrivalRecords from the output so we can reuse the
        // RMSAnalysis pipeline. Split into 100ms windows.
        let chunkBytes = 2 * 24_000 / 10  // 100ms @ 24k int16 = 4800 bytes
        var arrivals: [ArrivalRecord] = []
        var offset = 0
        var t = 0.0
        while offset < out.pcmInt16_24k.count {
            let end = min(offset + chunkBytes, out.pcmInt16_24k.count)
            let chunk = out.pcmInt16_24k.subdata(in: offset..<end)
            arrivals.append(ArrivalRecord(t: t, bytes: chunk.count, pcm: chunk))
            offset = end
            t += 0.1
        }
        let rms = RMSAnalysis.compute(arrivals: arrivals, binSec: 1.0)
        let label2 = "\(args.label)-playback-\(label)"

        // Write rendered output as WAV + per-second RMS report.
        let wavURL = args.outputDir.appendingPathComponent("\(label2).wav")
        try WAVWriter.writeInt16Mono(pcm: out.pcmInt16_24k, sampleRate: 24_000, to: wavURL)
        let csvURL = args.outputDir.appendingPathComponent("\(label2)-rms.csv")
        var csv = "t_sec,rms\n"
        for c in rms.perChunkRMS {
            csv += String(format: "%.3f,%.6f\n", c.t, c.rms)
        }
        try csv.write(to: csvURL, atomically: true, encoding: .utf8)

        print("\n--- playback offline render RMS: \(label2) ---")
        print(String(format: "  First-sec bin mean RMS : %.5f", rms.firstBinMean))
        print(String(format: "  Last-sec bin mean RMS  : %.5f", rms.lastBinMean))
        print(String(format: "  Ratio last/first       : %.3f  (1.0 = stable, < 0.8 = fading)",
                     rms.ratioLastToFirst))
        print(String(format: "  Linear slope per sec   : %+.6f  (negative = fading)",
                     rms.slopePerSec))
        print("  Per-second RMS (output of \(label)):")
        for b in rms.bins {
            let bar = String(repeating: "█", count: Int(b.rmsMean * 200))
            print(String(format: "    t=%4.1f-%4.1fs  mean=%.4f  max=%.4f  %@",
                         b.startSec, b.endSec, b.rmsMean, b.rmsMax, bar))
        }
        print("  WAV → \(wavURL.lastPathComponent)")
    }

    // Also print the input RMS for direct A/B comparison.
    var inputArrivals: [ArrivalRecord] = []
    var offset = 0
    var t = 0.0
    let chunkBytes = 2 * 24_000 / 10
    while offset < decoded.pcm.count {
        let end = min(offset + chunkBytes, decoded.pcm.count)
        let chunk = decoded.pcm.subdata(in: offset..<end)
        inputArrivals.append(ArrivalRecord(t: t, bytes: chunk.count, pcm: chunk))
        offset = end
        t += 0.1
    }
    let inRMS = RMSAnalysis.compute(arrivals: inputArrivals, binSec: 1.0)
    print("\n--- INPUT RMS (for comparison) ---")
    print(String(format: "  First-sec bin mean RMS : %.5f", inRMS.firstBinMean))
    print(String(format: "  Last-sec bin mean RMS  : %.5f", inRMS.lastBinMean))
    print(String(format: "  Ratio last/first       : %.3f", inRMS.ratioLastToFirst))
    print(String(format: "  Linear slope per sec   : %+.6f", inRMS.slopePerSec))
}

/// Live-mode playback test: drives a real `AVAudioEngine` against the
/// current default audio device and captures post-mixer audio via a
/// tap. This exercises the part of production we couldn't simulate
/// offline — the engine's render thread is driven by the device's
/// clock, the same suspect we have for the fade-out report.
func runLivePlaybackTest(decoded: AudioReader.Decoded, args: CLIArgs) async throws {
    print("\n[live-playback] running live AVAudioEngine against default audio device")
    print("  → renderDur=\(String(format: "%.1fs", decoded.totalDurationSec + 3.0)) (input + 3s drain)")
    let renderDur = decoded.totalDurationSec + 3.0

    for useTimePitch in [true, false] {
        let label = useTimePitch ? "live-with-timepitch" : "live-no-timepitch"
        let renderer = PlaybackLiveRender(
            inputPCM24kInt16: decoded.pcm,
            renderDurationSec: renderDur,
            useTimePitch: useTimePitch
        )
        let out = try await renderer.render()
        let frameCount = out.capturedFloatPCM.count / MemoryLayout<Float>.size
        let capturedSec = Double(frameCount) / out.captureSampleRate
        print(String(format: "[live-playback] %@ captured %d frames (%.2fs) at %.0fHz",
                     label, frameCount, capturedSec, out.captureSampleRate))

        // Convert captured float32 PCM at hardware rate → int16 24kHz so
        // we can analyse with the same RMS pipeline as the model output.
        let int16Data = try convertFloatToInt16AtSampleRate(
            floatPCM: out.capturedFloatPCM,
            sourceSampleRate: out.captureSampleRate,
            targetSampleRate: 24_000
        )

        // Build ArrivalRecords from the output for RMS analysis.
        let chunkBytes = 2 * 24_000 / 10  // 100 ms @ 24k int16
        var arrivals: [ArrivalRecord] = []
        var offset = 0
        var t = 0.0
        while offset < int16Data.count {
            let end = min(offset + chunkBytes, int16Data.count)
            let chunk = int16Data.subdata(in: offset..<end)
            arrivals.append(ArrivalRecord(t: t, bytes: chunk.count, pcm: chunk))
            offset = end
            t += 0.1
        }
        let rms = RMSAnalysis.compute(arrivals: arrivals, binSec: 1.0)
        let label2 = "\(args.label)-\(label)"
        let wavURL = args.outputDir.appendingPathComponent("\(label2).wav")
        try WAVWriter.writeInt16Mono(pcm: int16Data, sampleRate: 24_000, to: wavURL)

        print("\n--- live-render RMS: \(label2) ---")
        print(String(format: "  First-sec bin mean RMS : %.5f", rms.firstBinMean))
        print(String(format: "  Last-sec bin mean RMS  : %.5f", rms.lastBinMean))
        print(String(format: "  Ratio last/first       : %.3f", rms.ratioLastToFirst))
        print(String(format: "  Linear slope per sec   : %+.6f  (negative = fading)",
                     rms.slopePerSec))
        print("  Per-second RMS:")
        for b in rms.bins {
            let bar = String(repeating: "█", count: Int(b.rmsMean * 200))
            print(String(format: "    t=%4.1f-%4.1fs  mean=%.4f  max=%.4f  %@",
                         b.startSec, b.endSec, b.rmsMean, b.rmsMax, bar))
        }
        print("  WAV → \(wavURL.lastPathComponent)")
    }
}

private func convertFloatToInt16AtSampleRate(floatPCM: Data,
                                             sourceSampleRate: Double,
                                             targetSampleRate: Double) throws -> Data {
    let fSrc = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                              sampleRate: sourceSampleRate,
                              channels: 1, interleaved: false)!
    let fDst = AVAudioFormat(commonFormat: .pcmFormatInt16,
                              sampleRate: targetSampleRate,
                              channels: 1, interleaved: true)!
    let srcFrames = AVAudioFrameCount(floatPCM.count / MemoryLayout<Float>.size)
    let src = AVAudioPCMBuffer(pcmFormat: fSrc, frameCapacity: srcFrames)!
    src.frameLength = srcFrames
    floatPCM.withUnsafeBytes { raw in
        _ = memcpy(src.floatChannelData![0], raw.baseAddress!, floatPCM.count)
    }
    let dstFrames = AVAudioFrameCount(Double(srcFrames) * targetSampleRate / sourceSampleRate) + 256
    let dst = AVAudioPCMBuffer(pcmFormat: fDst, frameCapacity: dstFrames)!
    let conv = AVAudioConverter(from: fSrc, to: fDst)!
    var didFeed = false
    var convError: NSError?
    conv.convert(to: dst, error: &convError) { _, statusPtr in
        if !didFeed {
            didFeed = true
            statusPtr.pointee = .haveData
            return src
        }
        statusPtr.pointee = .endOfStream
        return nil
    }
    if let convError {
        throw PacingEvalError.audioRead("post-mixer converter: \(convError.localizedDescription)")
    }
    let bytes = Int(dst.frameLength) * 2
    var out = Data(count: bytes)
    out.withUnsafeMutableBytes { raw in
        _ = memcpy(raw.baseAddress!, dst.int16ChannelData![0], bytes)
    }
    return out
}

// MARK: - main

@main
struct PacingEvalCLI {
    static func main() async {
        do {
            let args = try CLIArgs.parse()
            // Playback-test mode doesn't talk to any provider; skip the API
            // key check so we can run fade diagnosis without exposing a key.
            let apiKey: String
            if args.playbackTestOnly {
                apiKey = ""
            } else {
                let envVar: String
                switch args.provider {
                case .openAIRealtime:    envVar = "OPENAI_API_KEY"
                case .geminiLiveTranslate: envVar = "GEMINI_API_KEY"
                }
                guard let k = ProcessInfo.processInfo.environment[envVar], !k.isEmpty else {
                    throw PacingEvalError.missingApiKey(envVar)
                }
                apiKey = k
            }

            // Wire sample rate depends on the provider. AudioReader must
            // decode to this rate so the PCM sent to the stream is already
            // at the rate the stream expects (streams base64-encode pcm as-is).
            let wireSampleRate = args.provider.inputWireSampleRate

            print("[pacing-eval] audio=\(args.audioPath) target=\(args.targetLang.rawValue) provider=\(args.provider.rawValue) out=\(args.outputDir.path) runs=\(args.runs) playback-test=\(args.playbackTestOnly)")

            // Playback-test always uses 24 kHz (tests the AVAudioEngine chain,
            // independent of provider). Live session decodes to wireSampleRate.
            let readerRate = args.playbackTestOnly ? 24_000 : wireSampleRate
            let reader = AudioReader(url: URL(fileURLWithPath: args.audioPath), chunkMs: 100, targetSampleRate: readerRate)
            let decoded = try reader.decode()
            print(String(format: "[pacing-eval] decoded %.2fs audio (%d chunks of %dms) at %dHz",
                         decoded.totalDurationSec,
                         decoded.chunkCount,
                         100,
                         decoded.sampleRate))

            if args.playbackTestOnly {
                try runPlaybackTest(decoded: decoded, args: args)
                try await runLivePlaybackTest(decoded: decoded, args: args)
                return
            }

            let writer = ReportWriter(outputDir: args.outputDir)
            var allRuns: [AggregateAcrossRuns.RunSummary] = []

            for runIndex in 1...args.runs {
                print("\n========== run \(runIndex) / \(args.runs) ==========")
                let chunks = AudioChunkIterator(decoded: decoded)
                let session = Session(
                    apiKey: apiKey,
                    targetLang: args.targetLang,
                    chunks: chunks,
                    provider: args.provider,
                    wireSampleRate: wireSampleRate,
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

                // Save the raw model output as a WAV (24 kHz int16 mono)
                // so we can listen and visually inspect the amplitude
                // envelope independent of our playback pipeline.
                let assembled = result.arrivals.reduce(into: Data()) { $0.append($1.pcm) }
                let wavURL = args.outputDir.appendingPathComponent("\(runLabel)-model-output.wav")
                try WAVWriter.writeInt16Mono(pcm: assembled, sampleRate: 24_000, to: wavURL)

                // RMS analysis: per-chunk + 1-second bins + linear-fit
                // slope. Tells us whether the model's own output fades
                // over a 20-30s session.
                let rms = RMSAnalysis.compute(arrivals: result.arrivals, binSec: 1.0)
                let rmsCsvURL = args.outputDir.appendingPathComponent("\(runLabel)-rms.csv")
                var rmsCsv = "t_sec,rms\n"
                for c in rms.perChunkRMS {
                    rmsCsv += String(format: "%.3f,%.6f\n", c.t, c.rms)
                }
                try rmsCsv.write(to: rmsCsvURL, atomically: true, encoding: .utf8)
                print("\n--- model-output RMS analysis: \(runLabel) ---")
                print(String(format: "  First-sec bin mean RMS : %.5f", rms.firstBinMean))
                print(String(format: "  Last-sec bin mean RMS  : %.5f", rms.lastBinMean))
                print(String(format: "  Ratio last/first       : %.3f  (1.0 = stable, < 0.8 = fading)",
                             rms.ratioLastToFirst))
                print(String(format: "  Linear slope per sec   : %+.5f  (negative = fading)",
                             rms.slopePerSec))
                print("  Per-second RMS:")
                for b in rms.bins {
                    let bar = String(repeating: "█", count: Int(b.rmsMean * 200))
                    print(String(format: "    t=%4.1f-%4.1fs  mean=%.4f  max=%.4f  n=%d  %@",
                                 b.startSec, b.endSec, b.rmsMean, b.rmsMax, b.chunkCount, bar))
                }
                print("  WAV → \(wavURL.lastPathComponent)")

                // Per-run: sweep pre-roll variants against the SAME
                // recorded arrival timeline so we can compare them
                // apples-to-apples (same model behaviour, different
                // pacing decisions).
                let variants: [(name: String, preroll: Double, fixed: Double?)] = [
                    ("v3-adaptive", 0.0, nil),
                    ("fixed-1.0", 0.0, 1.0),
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
