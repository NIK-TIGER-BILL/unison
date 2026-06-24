import CoreAudio
import Foundation
import UnisonAudio
import UnisonDomain

struct CLIOptions {
    var duration: Int = 30
    var phase: String = "both"
    var silent: Bool = false
    var jsonOut: String?
    var subcommand: String?
}

func parseArgs() -> CLIOptions {
    var opts = CLIOptions()
    var i = 1
    let args = CommandLine.arguments
    if args.count >= 2, !args[1].hasPrefix("-") {
        opts.subcommand = args[1]
        i = 2
    }
    while i < args.count {
        let a = args[i]
        switch a {
        case "--duration":
            i += 1
            opts.duration = Int(args[i]) ?? 30
        case "--phase":
            i += 1
            opts.phase = args[i]
        case "--silent":
            opts.silent = true
        case "--json-out":
            i += 1
            opts.jsonOut = args[i]
        case "-h", "--help":
            printUsage()
            exit(0)
        case "--global", "--unmuted", "--timepitch", "--mixer", "--bind", "--dual", "--completions":
            break  // consumed by the repro-teardown subcommand directly
        case "--teardown", "--loops":
            i += 1  // value read directly by the repro-teardown subcommand
        default:
            FileHandle.standardError.write("Unknown arg: \(a)\n".data(using: .utf8)!)
            exit(1)
        }
        i += 1
    }
    return opts
}

func printUsage() {
    print("""
    tap-benchmark [sanity-check] [options]

    Subcommands:
      sanity-check                  Tap Zoom (us.zoom.xos) for 10s, print RMS

    Options:
      --duration N                  Duration in seconds (default 30)
      --phase {blackhole,tap,both}  Which phases to run (default both)
      --silent                      Route output to a null device for the tap phase
      --json-out PATH               Write JSON report to PATH
      -h, --help                    Show this help
    """)
}

func defaultOutputDeviceID() -> AudioDeviceID {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var id: AudioDeviceID = 0
    var size: UInt32 = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id
    )
    return id
}

/// Find the BlackHole 16ch device ID by scanning CoreAudio's device list
/// directly. `CoreAudioDeviceRegistry.findBlackHole16ch()` was removed from
/// production code — this benchmark keeps its own lookup so the 16ch phase
/// remains self-contained.
func blackHole16chDeviceID() -> AudioDeviceID? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)

    for id in ids {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var cfName: CFString?
        let status = withUnsafeMutablePointer(to: &cfName) { ptr in
            AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
        }
        if status == noErr, let name = cfName as String?,
           name.lowercased().contains("blackhole 16ch") {
            return id
        }
    }
    return nil
}

func runMain() async throws {
    let opts = parseArgs()

    if opts.subcommand == "sanity-check" {
        await SanityCheck.run()
        return
    } else if opts.subcommand == "repro-teardown" {
        // A/B: does a mixdown (only-selected) tap wedge a subsequent
        // AVAudioEngine.stop() the way a global (all-except) tap does not?
        let global = CommandLine.arguments.contains("--global")
        let unmuted = CommandLine.arguments.contains("--unmuted")
        await ReproTeardown.run(global: global, unmuted: unmuted)
        return
    } else if opts.subcommand == "repro-devicechange" {
        // Does a default-output-device change (what connecting BT headphones
        // does) kill the production AVAudioOutputMixer engine?
        await ReproDeviceChange.run()
        return
    } else if let sub = opts.subcommand {
        FileHandle.standardError.write("Unknown subcommand: \(sub)\n".data(using: .utf8)!)
        exit(1)
    }

    let bhDevice = blackHole16chDeviceID()
    let blackHolePresent = bhDevice != nil
    let defaultOut = defaultOutputDeviceID()

    var bhResult = PhaseResult(name: "BlackHole 16ch", metrics: nil, skipReason: nil)
    var tapResult = PhaseResult(name: "Process Tap", metrics: nil, skipReason: nil)

    if opts.phase == "blackhole" || opts.phase == "both" {
        if let dev = bhDevice {
            print("Running BlackHole phase (\(opts.duration)s)...")
            let cfg = PhaseConfig(phase: .blackhole, durationSeconds: opts.duration,
                                  outputDeviceID: dev, silentMode: false)
            let run = BenchmarkRun(config: cfg)
            do {
                let metrics = try await run.run()
                bhResult = PhaseResult(name: "BlackHole 16ch", metrics: metrics, skipReason: nil)
            } catch {
                bhResult = PhaseResult(name: "BlackHole 16ch", metrics: nil,
                                        skipReason: "error: \(error)")
            }
        } else {
            bhResult = PhaseResult(name: "BlackHole 16ch", metrics: nil,
                                    skipReason: "BlackHole 16ch not installed")
        }
    }

    if opts.phase == "both" {
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    if opts.phase == "tap" || opts.phase == "both" {
        print("Running Process Tap phase (\(opts.duration)s)...")
        let cfg = PhaseConfig(phase: .tap, durationSeconds: opts.duration,
                              outputDeviceID: defaultOut, silentMode: opts.silent)
        let run = BenchmarkRun(config: cfg)
        do {
            let metrics = try await run.run()
            tapResult = PhaseResult(name: "Process Tap", metrics: metrics, skipReason: nil)
        } catch {
            tapResult = PhaseResult(name: "Process Tap", metrics: nil,
                                     skipReason: "error: \(error)")
        }
    }

    let setupFriendly: SetupFriendlyResult
    if blackHolePresent {
        setupFriendly = .skipped
    } else if tapResult.metrics != nil {
        setupFriendly = .pass
    } else {
        setupFriendly = .fail
    }

    let report = BenchmarkReport(
        timestampISO: ISO8601DateFormatter().string(from: Date()),
        durationSeconds: opts.duration,
        clickCount: opts.duration * 5,
        blackhole: bhResult,
        tap: tapResult,
        setupFriendly: setupFriendly,
        blackHolePresent: blackHolePresent,
        isVM: ProcessInfo.processInfo.environment["VM_BENCHMARK"] == "1"
    )

    print()
    print(report.renderText())

    if let path = opts.jsonOut {
        do {
            try report.renderJSON().write(to: URL(fileURLWithPath: path))
            print("\nJSON written to \(path)")
        } catch {
            FileHandle.standardError.write(
                "Failed to write JSON: \(error)\n".data(using: .utf8)!)
        }
    }
}

signal(SIGINT) { _ in
    print("\nInterrupted — exiting.")
    exit(130)
}

Task {
    do {
        try await runMain()
    } catch {
        FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    exit(0)
}

// Run the main dispatch queue (also satisfies AppKit's run-loop requirement
// when SanityCheck.swift imports AppKit for NSWorkspace).
dispatchMain()
