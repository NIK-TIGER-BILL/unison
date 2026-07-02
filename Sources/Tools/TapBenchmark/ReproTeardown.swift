import AVFoundation
import CoreAudio
import Foundation
import UnisonAudio
import UnisonDomain

/// Isolates the Stop-teardown wedge that appears after a CoreAudio process tap.
/// Runs an output engine playing a tone, cycles a `ProcessTapCapture` `--loops N`
/// times, then tears the engine down OFF the main actor (like production). The
/// last `[repro] step=…` line with no successor pins the blocking call.
///
/// CONCLUSION (found here, fixed in AVAudioOutputMixer.stop): the wedge is
/// `AVAudioPlayerNode.stop()` — its `.dataPlayedBack` completion-handler flush
/// never returns while a tap was active in the session. `--completions` on the
/// raw path reproduces it; `player.reset()` instead of `.stop()` clears it.
/// `engine.stop()` itself does NOT wedge. Kept as a regression harness.
///
/// `--mixer` uses the production `AVAudioOutputMixer` (player→timePitch→mainMixer,
/// dual players, device binding); otherwise a minimal raw engine (player→mainMixer).
///
/// Usage: repro-teardown [--mixer] [--global] [--unmuted] [--teardown M] [--loops N]
enum ReproTeardown {
    static func mark(_ s: String) {
        FileHandle.standardError.write("[repro] \(s)\n".data(using: .utf8)!)
    }

    @MainActor
    static func run(global: Bool, unmuted: Bool = false) async {
        let useMixer = CommandLine.arguments.contains("--mixer")
        let method = argValue("--teardown") ?? "stop"
        let loops = Int(argValue("--loops") ?? "1") ?? 1
        let bid = Bundle.main.bundleIdentifier ?? "com.unison.tapbenchmark"
        let scope: TapScope = global ? .allExcept([]) : .onlySelected([bid])
        let mute: CATapMuteBehavior = unmuted ? .unmuted : .mutedWhenTapped
        mark("=== useMixer=\(useMixer) global=\(global) muted=\(!unmuted) teardown=\(method) loops=\(loops) ===")

        if useMixer {
            let mixer = AVAudioOutputMixer()
            mark("step=mixer.start")
            do { try await mixer.start(deviceUID: nil) } catch { mark("mixer.start FAILED \(error)"); return }
            mark("step=mixer.start.done")
            var cont: AsyncStream<AudioFrame>.Continuation!
            let s = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(8)) { cont = $0 }
            let feeder = Task { await mixer.playTranslated(s) }
            let yieldFrame = cont!  // immutable copy: silences var-capture-in-@Sendable
            let prod = toneProducer { yieldFrame.yield($0) }
            try? await Task.sleep(for: .seconds(1))
            await cycleTaps(scope: scope, mute: mute, loops: loops)
            Task.detached {
                mark("step=mixer.stop  (<-- LAST line = WEDGED)")
                mixer.stop()
                mark("step=teardown.done  *** NO WEDGE (mixer) ***")
            }
            try? await Task.sleep(for: .seconds(8))
            mark("=== 8s after teardown (mixer, loops=\(loops)) ===")
            prod.cancel(); feeder.cancel(); cont.finish()
        } else {
            let bindDevice = CommandLine.arguments.contains("--bind")
            let withTP = CommandLine.arguments.contains("--timepitch")
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
            engine.attach(player)
            if withTP {
                engine.attach(timePitch)
                engine.connect(player, to: timePitch, format: fmt)
                engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
            } else {
                engine.connect(player, to: engine.mainMixerNode, format: fmt)
            }
            if bindDevice, let au = engine.outputNode.audioUnit {
                var dev = AudioObjectID(0)
                var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var sz = UInt32(MemoryLayout<AudioObjectID>.size)
                AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
                if dev != 0 { AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioObjectID>.size)) }
            }
            mark("step=graph bind=\(bindDevice) timePitch=\(withTP)")
            mark("step=engine.start")
            do { try engine.start() } catch { mark("engine.start FAILED \(error)"); return }
            mark("step=engine.start.done")
            // Optional second player (like AVAudioOutputMixer's originalPlayer).
            let dual = CommandLine.arguments.contains("--dual")
            let player2 = AVAudioPlayerNode()
            if dual { engine.attach(player2); engine.connect(player2, to: engine.mainMixerNode, format: fmt) }
            // Optional completion-handler scheduling (like AVAudioOutputMixer).
            let completions = CommandLine.arguments.contains("--completions")
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4_800)!
            buf.frameLength = 4_800
            var ph: Float = 0; let inc = Float(2.0 * Double.pi * 440.0 / 48_000.0)
            for i in 0..<4_800 { buf.floatChannelData![0][i] = 0.1 * sin(ph); ph += inc }
            if completions {
                // Reschedule off the render thread, hopping back to the main
                // actor (where `sched` is isolated) so the recursive call is
                // in-isolation — same continuous `.dataPlayedBack` queue as
                // AVAudioOutputMixer.scheduleTranslated, which is what wedges stop().
                func sched() { player.scheduleBuffer(buf, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in Task { @MainActor in sched() } } }
                sched()
            } else {
                // Fire-and-forget looping schedule. The async `scheduleBuffer`
                // alternative suspends until the buffer finishes — which for
                // `.loops` never happens — so the completion-handler overload is
                // the correct one. Call it through a synchronous nested func so
                // the compiler doesn't flag "consider the async alternative".
                func scheduleLoop() {
                    player.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
                }
                scheduleLoop()
            }
            player.play()
            if dual { player2.play() }
            try? await Task.sleep(for: .seconds(1))
            await cycleTaps(scope: scope, mute: mute, loops: loops)
            Task.detached {
                mark("step=player.stop"); player.stop()
                mark("step=teardown(\(method))  (<-- LAST line = WEDGED)")
                switch method {
                case "pause": engine.pause()
                case "reset": engine.reset()
                case "detach-stop": engine.detach(player); engine.stop()
                default: engine.stop()
                }
                mark("step=teardown.done  *** NO WEDGE (\(method)) ***")
            }
            try? await Task.sleep(for: .seconds(8))
            mark("=== 8s after teardown (raw \(method), loops=\(loops)) ===")
        }
    }

    static func cycleTaps(scope: TapScope, mute: CATapMuteBehavior, loops: Int) async {
        mark("step=cap.cycles scope=\(scope) loops=\(loops)")
        for i in 1...loops {
            let cap = ProcessTapCapture(scope: scope, muteBehavior: mute)
            let stream = cap.start()
            let d = Task.detached { for await _ in stream {} }
            try? await Task.sleep(for: .milliseconds(700))
            cap.stop()
            d.cancel()
            if loops > 1 { mark("loop=\(i)/\(loops) done") }
        }
    }

    static func toneProducer(_ yield: @escaping @Sendable (AudioFrame) -> Void) -> Task<Void, Never> {
        Task.detached {
            var ph: Float = 0; let inc = Float(2.0 * Double.pi * 440.0 / 48_000.0)
            while !Task.isCancelled {
                var data = Data(count: 4_800 * MemoryLayout<Float>.size)
                data.withUnsafeMutableBytes { raw in
                    let p = raw.bindMemory(to: Float.self)
                    for i in 0..<4_800 { p[i] = 0.1 * sin(ph); ph += inc }
                }
                yield(AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32))
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private static func argValue(_ flag: String) -> String? {
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: flag), i + 1 < a.count { return a[i + 1] }
        return nil
    }
}
