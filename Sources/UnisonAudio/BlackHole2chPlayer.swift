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
    /// Serializes engine-lifecycle transitions (start / stop / device-change
    /// reconfigure) so a config-change self-heal can't race a stop().
    private let engineLock = NSLock()
    /// Observes `AVAudioEngineConfigurationChange` on `engine` and restarts the
    /// BlackHole 2ch route. Same self-heal the speakers path
    /// (`AVAudioOutputMixer`) uses; created on first start. NOTE: this engine is
    /// pinned to the explicit BlackHole 2ch device (not the system default), so
    /// a plain default-output change (the BT-connect case) usually won't notify
    /// it — this covers a BlackHole *format renegotiation* and keeps the
    /// self-heal uniform across the output engines; the BT fix proper lives in
    /// `AVAudioOutputMixer`.
    private var configObserver: DebouncedNotificationObserver?
    /// Latches on first `startIfNeeded()` so a stop-restart cycle doesn't
    /// `engine.attach(_:)` already-attached nodes — same contract as
    /// `AVAudioOutputMixer.attached` (attach-twice throws an Obj-C
    /// exception, non-recoverable from Swift). `stop()` deliberately
    /// does not detach.
    private var attached = false
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
    /// Seam-declick state — parity with `AVAudioOutputMixer`'s translated
    /// path (the peer used to hear the boundary clicks the local listener
    /// didn't). `lastSample` = final sample of the previous buffer;
    /// `queueEndsAt` = host-clock second the queued audio finishes, the
    /// wall-clock dryness model `SeamDeclick.resumeDecision` reads. Guarded
    /// by `seamLock`: `schedule` runs on the `play(_:)` consumer task while
    /// `play(_:)`'s reset can belong to the next session after a stop-restart.
    private let seamLock = NSLock()
    private var lastSample: Float = 0
    private var queueEndsAt: Double = 0

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
        resetSeamState()
        for await frame in frames {
            schedule(frame)
        }
        Self.log.info("play() — frame stream finished")
    }

    public func stop() {
        engineLock.lock()
        defer { engineLock.unlock() }
        // Latch stopped + tear down the device-change observer first so a
        // config-change landing during teardown can't restart the engine.
        started = false
        configObserver?.stop()
        pacing?.stop()
        // Reset (not stop) the player — parity with AVAudioOutputMixer.stop().
        // `AVAudioPlayerNode.stop()` flushes the pending completion handlers
        // (our pacing `didComplete` hooks), and that flush wedges inside
        // coreaudiod whenever a CoreAudio Process Tap was active in the
        // session (the Stop-hang root cause, VM-verified 3/3 on the mixer).
        // `.call` mode — the only mode that runs this player — ALWAYS has the
        // tap active, so this path was still carrying the wedge-prone call.
        // `reset()` clears the scheduled buffers without the flush.
        player.reset()
        engine.stop()
        closeDumpFileIfNeeded()
    }

    /// Sync helper — Swift 6 strict concurrency disallows `NSLock.lock`
    /// from inside an async function, so the seam-state reset lives here
    /// and is called from `play(_:)`. Same pattern as
    /// `AVAudioOutputMixer.resetPlaybackCounters`.
    private func resetSeamState() {
        seamLock.lock(); defer { seamLock.unlock() }
        lastSample = 0
        queueEndsAt = 0
    }

    private func startIfNeeded() throws {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard !started else { return }
        try configureAndStartLocked()
        started = true
        // Self-heal on output-device changes (same as the speakers path).
        if configObserver == nil {
            configObserver = DebouncedNotificationObserver(
                name: .AVAudioEngineConfigurationChange, object: engine
            ) { [weak self] in
                self?.handleConfigurationChange()
            }
        }
        configObserver?.start()
    }

    /// Resolve + bind the BlackHole 2ch device, wire the graph, and start the
    /// engine + player. Shared by `startIfNeeded()` and the device-change
    /// self-heal. Caller must hold `engineLock`.
    private func configureAndStartLocked() throws {
        guard let bh2 = registry.findBlackHole2ch() else {
            Self.log.error("startIfNeeded — BlackHole 2ch device not found in registry")
            throw NSError(domain: "BlackHole2chPlayer", code: -1)
        }
        Self.log.info("startIfNeeded — found BlackHole 2ch device uid=\(bh2.uid)")

        if !attached {
            engine.attach(player)
            engine.attach(timePitch)
            attached = true
        }

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
        if pacing == nil {
            pacing = PlaybackPacing(player: player,
                                    timePitch: timePitch,
                                    log: Self.log,
                                    label: "blackhole2ch")
        }
        Self.log.info("startIfNeeded — engine started; player playing; ready to schedule buffers")
    }

    /// Self-heal after an `AVAudioEngineConfigurationChange` — the engine
    /// stopped itself on a device/format change. Re-resolve + re-bind the
    /// BlackHole 2ch route and restart, re-priming pacing (the `play(_:)`
    /// loop is still feeding frames). No-op once stopped. Runs on the
    /// observer's serial queue; `engineLock` serializes it with stop().
    private func handleConfigurationChange() {
        engineLock.lock()
        defer { engineLock.unlock() }
        guard started else {
            Self.log.info("AVAudioEngineConfigurationChange ignored — BlackHole player already stopped")
            return
        }
        Self.log.info("AVAudioEngineConfigurationChange — output device/format changed; rebuilding BlackHole 2ch route and restarting")
        player.reset()
        // The reset flushed the queue — the seam model must restart from
        // silence, or the first post-reconfigure buffer ramps from a stale
        // sample against a queue-end that's ahead of reality.
        resetSeamState()
        do {
            try configureAndStartLocked()
            pacing?.reset()
            pacing?.start()
            Self.log.info("reconfigure — BlackHole engine restarted (isRunning=\(engine.isRunning))")
        } catch {
            Self.log.error("reconfigure — failed to restart BlackHole engine after device change: \(String(describing: error))")
        }
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
        // Hard latency cap — parity with the speakers path. After a network
        // stall recovers, the model dumps a multi-second burst; the gentle
        // pacing rate (≤1.06×) can't drain it, so without this gate the PEER
        // keeps hearing tens-of-seconds-stale translation long after the
        // local listener resynced. Drop until the queue drains to the floor
        // (`admit()`'s hysteresis), resyncing the virtual mic to live.
        if let pacing, !pacing.admit() { return }
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

        // Seam declick — parity with the speakers path: ramp the first ~2 ms
        // from where the audio actually left off (previous buffer's last
        // sample, or 0 after the player drained), so resampler/AGC boundary
        // steps and resume-from-silence onsets don't click in the peer's ear.
        let now = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let bufDurSec = Double(buf.frameLength) / playerFormat.sampleRate
            / Double(max(0.5, timePitch.rate))
        seamLock.lock()
        let (resumingFromSilence, newQueueEnd) = SeamDeclick.resumeDecision(
            now: now, queueEndsAt: queueEndsAt, bufferDurationSec: bufDurSec)
        queueEndsAt = newQueueEnd
        let prevSample = lastSample
        seamLock.unlock()
        if !SeamDeclick.disabled {
            SeamDeclick.ramp(buf, from: resumingFromSilence ? 0 : prevSample)
        }
        if let ch = buf.floatChannelData, buf.frameLength > 0 {
            let last = ch[0][Int(buf.frameLength) - 1]
            seamLock.lock(); lastSample = last; seamLock.unlock()
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
        // Throwing write — legacy `write(_:)` raises an uncatchable ObjC
        // exception on I/O failure (crash mid-call over a test dump).
        try? handle.write(contentsOf: frame.pcm)
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
            try? handle.write(contentsOf: Self.buildWAVHeader(sampleRate: sampleRate, channels: channels, dataSize: 0xFFFF_FFFF))
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
        try? handle.write(contentsOf: Self.uint32LE(fileSize))
        try? handle.seek(toOffset: 40)
        try? handle.write(contentsOf: Self.uint32LE(dataSize))
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
        // Sentinel-aware RIFF size — see AVAudioOutputMixer.buildWAVHeader.
        let fileSize = dataSize == 0xFFFF_FFFF ? dataSize : dataSize &+ 36

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
