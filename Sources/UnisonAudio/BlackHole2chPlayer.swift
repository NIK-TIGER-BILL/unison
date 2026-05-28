import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class BlackHole2chPlayer: AudioPlayer, @unchecked Sendable {
    /// Diagnostic logger for the BlackHole 2ch virtual-mic player. Logs
    /// lifecycle events (engine start / device bind), and any frame format
    /// mismatch that would silently drop audio. Mirrors to
    /// `~/Library/Logs/Unison/unison.log` — see `UnisonLog`.
    private static let log = UnisonLog(category: "AudioOutput")

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Time-stretch node between `player` and the engine's main mixer.
    /// Its `rate` is modulated by `pacing` based on queue depth so
    /// OpenAI Realtime's burst-rate audio doesn't accumulate unbounded
    /// latency on the BlackHole 2ch route to the conferencing app. The
    /// peer still hears the user's own translated voice at the right
    /// pitch — only the tempo is adjusted to keep the queue ≤ ~1s.
    private let timePitch = AVAudioUnitTimePitch()
    private let registry: CoreAudioDeviceRegistry
    private var started = false
    /// Cached output format. Same instance used to connect the node
    /// graph and to build per-chunk `AVAudioPCMBuffer`s — sharing it
    /// avoids the tiny per-chunk allocation and guarantees the player
    /// accepts each scheduled buffer.
    private let playerFormat: AVAudioFormat
    /// Pacing controller for adaptive playback rate. Created lazily
    /// once the engine is up; `reset()` at the start of each `play(_:)`
    /// invocation so a stop-restart cycle doesn't carry stale state.
    private var pacing: PlaybackPacing?
    /// Latches once per `play(_:)` invocation to keep the format-mismatch
    /// warning out of the per-frame hot path. The first dropped frame
    /// shouts loudly so the diagnostic dump captures it; subsequent
    /// drops are silent until the player restarts.
    private var loggedFormatMismatch = false
    /// Latches once per `play(_:)` invocation when a frame is successfully
    /// scheduled. Used to surface "the pipeline started delivering audio"
    /// exactly once so the log isn't drowned by the per-chunk firehose.
    private var loggedFirstFrame = false
    /// Per-`play(_:)` chunk index for periodic RMS sampling.
    private var chunkIndex = 0
    /// Compensating AGC. Same instance type as the speakers path —
    /// applied to the translated me-stream that the peer will hear
    /// through the virtual mic.
    private let agc = CompensatingAGCRunner()

    /// Test-only WAV capture handle. When `UNISON_DUMP_OUTPUT_WAV=path` is
    /// set in the process environment, every scheduled frame's float32 PCM
    /// is appended here so the VM integration test can assert that real
    /// audio (not just `scheduleBuffer` calls) crossed the pipeline. The
    /// handle is opened on first frame and closed in `stop()`. If the
    /// process is killed before `stop()`, the WAV header has a placeholder
    /// size — host-side analysis treats anything past offset 44 as float32
    /// samples regardless.
    private var dumpHandle: FileHandle?
    private var dumpedByteCount: UInt32 = 0

    public init(registry: CoreAudioDeviceRegistry) {
        self.registry = registry
        self.playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000,
                                          channels: 1,
                                          interleaved: false)!
    }

    public func play(_ frames: AsyncStream<AudioFrame>) async {
        Self.log.info("play() entering — about to start engine + iterate frames")
        do {
            try startIfNeeded()
        } catch {
            Self.log.error("play() — startIfNeeded threw: \(String(describing: error)); aborting (no audio will be scheduled)")
            return
        }
        loggedFormatMismatch = false
        loggedFirstFrame = false
        chunkIndex = 0
        pacing?.reset()
        pacing?.start()
        agc.reset()
        for await frame in frames {
            schedule(frame)
        }
        Self.log.info("play() — frame stream finished")
    }

    public func stop() {
        pacing?.stop()
        player.stop()
        engine.stop()
        started = false
        closeDumpFileIfNeeded()
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        guard let bh2 = registry.findBlackHole2ch() else {
            Self.log.error("startIfNeeded — BlackHole 2ch device not found in registry")
            throw NSError(domain: "BlackHole2chPlayer", code: -1)
        }
        Self.log.info("startIfNeeded — found BlackHole 2ch device uid=\(bh2.uid)")

        engine.attach(player)
        engine.attach(timePitch)

        // CRITICAL: assign the output device BEFORE wiring graph connections.
        // AVAudioEngine resolves the implicit `mainMixerNode → outputNode`
        // connection against the current output device's hardware sample
        // rate the first time any node connection touches the mixer.
        // Changing the device on the output AudioUnit *after* that point
        // leaves the engine routing to the old (default) device — which
        // is exactly the silent-no-audio-on-BlackHole bug we hit.
        if let deviceID = audioDeviceID(forUID: bh2.uid) {
            var id = deviceID
            let status = AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Self.log.error("startIfNeeded — AudioUnitSetProperty(CurrentDevice → \(bh2.uid)) failed status=\(status)")
            } else {
                Self.log.info("startIfNeeded — output device bound to BlackHole 2ch (id=\(deviceID))")
            }
        } else {
            Self.log.error("startIfNeeded — audioDeviceID(forUID: \(bh2.uid)) returned nil; engine will route to default output")
        }

        // player → timePitch → mainMixer. timePitch starts at rate=1.0,
        // PlaybackPacing modulates it once the engine is running.
        engine.connect(player, to: timePitch, format: playerFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: playerFormat)
        timePitch.rate = 1.0

        do {
            try engine.start()
        } catch {
            Self.log.error("startIfNeeded — engine.start() threw: \(String(describing: error))")
            throw error
        }
        player.play()
        started = true
        if pacing == nil {
            pacing = PlaybackPacing(player: player,
                                    timePitch: timePitch,
                                    log: Self.log,
                                    label: "blackhole2ch")
        }
        Self.log.info("startIfNeeded — engine started; player playing; ready to schedule buffers")
    }

    private func schedule(_ frame: AudioFrame) {
        // Strict format check: the pipeline upstream is responsible for
        // delivering 48k F32 mono. A mismatch indicates a routing bug
        // — log loudly and drop rather than silently reformatting.
        guard frame.format == .float32,
              frame.sampleRate == Int(playerFormat.sampleRate),
              frame.channels == Int(playerFormat.channelCount) else {
            if !loggedFormatMismatch {
                loggedFormatMismatch = true
                Self.log.error("schedule — DROPPING frame: expected 48k F32 mono, got \(frame.sampleRate)Hz \(String(describing: frame.format)) × \(frame.channels)ch (\(frame.sampleCount) samples). Subsequent drops silent until next play().")
            }
            return
        }
        // Compensating AGC for `gpt-realtime-translate`'s amplitude
        // fade — same controller the speakers path uses. Applied here
        // so the peer (who hears our translated voice through their
        // Zoom etc.) gets a stable level just like the local
        // listener does.
        let frameDurationSec = Double(frame.sampleCount) / Double(frame.sampleRate)
        let (boostedPCM, appliedGain) = agc.apply(pcmF32: frame.pcm,
                                                   frameDurationSec: frameDurationSec)
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        boostedPCM.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(buf.floatChannelData![0], p, boostedPCM.count)
        }
        if chunkIndex % 10 == 0 {
            let rmsIn = Self.rms(frame)
            let boostedFrame = AudioFrame(pcm: boostedPCM,
                                          sampleRate: frame.sampleRate,
                                          channels: frame.channels,
                                          format: frame.format)
            let rmsOut = Self.rms(boostedFrame)
            Self.log.debug("[blackhole2ch] translated chunk \(chunkIndex) rms_in=\(String(format: "%.5f", rmsIn)) rms_out=\(String(format: "%.5f", rmsOut)) agc_gain=\(String(format: "%.3f", appliedGain))")
        }
        chunkIndex += 1
        // Hook the completion to drive the pacing controller's
        // "consumed" counter. Fires on a CoreAudio render thread —
        // PlaybackPacing.didComplete is lock-protected.
        player.scheduleBuffer(buf) { [weak pacing, frameCount] in
            pacing?.didComplete(samples: AVAudioFramePosition(frameCount))
        }
        pacing?.didSchedule(samples: AVAudioFramePosition(frameCount))
        appendFrameToDumpIfNeeded(frame)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            Self.log.info("schedule — first frame scheduled to BlackHole 2ch (\(frame.sampleRate)Hz × \(frame.channels)ch, \(frame.sampleCount) samples)")
        }
    }

    /// Root-mean-square amplitude of a float32 PCM frame. Cheap; called
    /// every 10th scheduled chunk for diagnostic logging.
    private static func rms(_ frame: AudioFrame) -> Float {
        guard frame.format == .float32, frame.sampleCount > 0 else { return 0 }
        var sumSq: Float = 0
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in 0..<frame.sampleCount {
                let s = p[i]
                sumSq += s * s
            }
        }
        return (sumSq / Float(frame.sampleCount)).squareRoot()
    }

    // MARK: - WAV dump (test-only)

    /// Opens the WAV dump file lazily on first frame so the captured format
    /// matches the actual pipeline output (no guessing the sample rate).
    /// Subsequent frames with mismatched format are silently dropped from
    /// the dump (still scheduled normally) — the WAV file represents the
    /// canonical scheduled stream.
    private func appendFrameToDumpIfNeeded(_ frame: AudioFrame) {
        if dumpHandle == nil {
            guard let path = ProcessInfo.processInfo.environment["UNISON_DUMP_OUTPUT_WAV"],
                  !path.isEmpty else { return }
            openDumpFile(path: path, sampleRate: UInt32(frame.sampleRate), channels: UInt16(frame.channels))
        }
        guard let handle = dumpHandle else { return }
        handle.write(frame.pcm)
        dumpedByteCount &+= UInt32(frame.pcm.count)
    }

    private func openDumpFile(path: String, sampleRate: UInt32, channels: UInt16) {
        let url = URL(fileURLWithPath: path)
        let existed = FileManager.default.fileExists(atPath: path)
        if !existed {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Self.log.error("dump — failed to open \(path) for WAV capture")
            return
        }
        if existed {
            // Reopen after stop() (e.g. start-stop-start lifecycle test):
            // seek to end so session #2's samples concatenate onto
            // session #1's, then recover the running byte count from
            // file size so the next closeDumpFileIfNeeded patches both
            // chunks correctly.
            let endOffset = (try? handle.seekToEnd()) ?? 44
            dumpedByteCount = UInt32(max(0, Int64(endOffset) - 44))
            Self.log.info("dump — reopened \(path), continuing at offset \(endOffset) (\(dumpedByteCount) data bytes preserved from previous session)")
        } else {
            // Fresh file: write placeholder header (sizes patched on
            // `stop()`). If the process is killed before stop runs,
            // host analysis still works by reading from offset 44 as
            // raw float32 LE.
            handle.write(Self.buildWAVHeader(sampleRate: sampleRate, channels: channels, dataSize: 0xFFFF_FFFF))
            dumpedByteCount = 0
            Self.log.info("dump — opened \(path) for WAV capture (\(sampleRate)Hz × \(channels)ch float32 LE)")
        }
        dumpHandle = handle
    }

    private func closeDumpFileIfNeeded() {
        guard let handle = dumpHandle else { return }
        let dataSize = dumpedByteCount
        let fileSize = dataSize &+ 36
        // Patch RIFF chunk size (offset 4) and data chunk size (offset 40).
        try? handle.seek(toOffset: 4)
        handle.write(Self.uint32LE(fileSize))
        try? handle.seek(toOffset: 40)
        handle.write(Self.uint32LE(dataSize))
        try? handle.close()
        dumpHandle = nil
        let durationSec = Double(dataSize) / 4.0 / 48000.0
        Self.log.info("dump — closed; \(dataSize) bytes (~\(String(format: "%.2f", durationSec))s of float32 mono)")
    }

    private static func buildWAVHeader(sampleRate: UInt32, channels: UInt16, dataSize: UInt32) -> Data {
        var header = Data()
        let bitsPerSample: UInt16 = 32
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let fileSize = dataSize &+ 36

        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE(16))           // fmt chunk size
        header.append(uint16LE(3))            // format = IEEE float
        header.append(uint16LE(channels))
        header.append(uint32LE(sampleRate))
        header.append(uint32LE(byteRate))
        header.append(uint16LE(blockAlign))
        header.append(uint16LE(bitsPerSample))
        header.append(contentsOf: "data".utf8)
        header.append(uint32LE(dataSize))
        return header
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }

    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }
}
