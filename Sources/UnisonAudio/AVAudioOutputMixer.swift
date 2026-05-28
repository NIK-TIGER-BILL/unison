import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class AVAudioOutputMixer: AudioOutputMixer, @unchecked Sendable {
    private static let log = UnisonLog(category: "AudioOutput")

    private let engine = AVAudioEngine()
    private let translatedPlayer = AVAudioPlayerNode()
    private let originalPlayer = AVAudioPlayerNode()
    /// Time-stretch node inserted between `translatedPlayer` and the
    /// main mixer. Its `rate` is modulated by `pacing` based on queue
    /// depth so OpenAI Realtime's burst-rate audio doesn't accumulate
    /// unbounded latency on Bluetooth output.
    private let timePitch = AVAudioUnitTimePitch()
    private let mixer: AVAudioMixerNode
    /// Cached 48k F32 mono format. We rebuild a new `AVAudioPCMBuffer`
    /// per scheduled chunk but stop rebuilding the `AVAudioFormat`
    /// — it's the same instance for every chunk and the connect-time
    /// node format, so sharing it avoids tiny allocations on the hot
    /// path and guarantees the player accepts each buffer.
    private let playerFormat: AVAudioFormat
    /// Pacing controller that drives `timePitch.rate`. Lifecycle is
    /// tied to the player; created lazily on first `start(_:)`.
    private var pacing: PlaybackPacing?
    /// Latches on first successful `start(_:)` so the second start in a
    /// stop-restart cycle doesn't `engine.attach(_:)` already-attached
    /// nodes. `AVAudioEngine.attach` is documented to throw an Obj-C
    /// exception if the same node is attached twice — and Obj-C
    /// exceptions in Swift are non-recoverable. The previous version
    /// got away with it on this OS revision but the contract is
    /// fragile; latching makes it explicit. `stop()` deliberately
    /// does *not* detach (the engine reuses the same player instances
    /// on restart, so detach+reattach buys nothing but reset risk).
    private var attached = false
    /// Frame counter for periodic RMS logging on the translated path —
    /// every 10th chunk (~1s at 100ms chunks) emits one debug line so
    /// diagnostics can see whether the source audio amplitude itself
    /// is drifting (as opposed to the playback path mangling it).
    private var translatedChunkIndex = 0
    /// Compensating AGC for translation audio. Counteracts the
    /// progressive amplitude fade that `gpt-realtime-translate` applies
    /// to its own output over long continuous sessions (verified by
    /// harness measurement; tests in CompensatingAGCTests).
    private let agc = CompensatingAGCRunner()
    /// Diagnostic counters for the "audio chunks cut off mid-play" bug.
    /// Compare schedule count (each successful scheduleBuffer call) vs
    /// playback count (from `.dataPlayedBack` completion type). If the
    /// player ever drops a buffer for whatever reason (engine reset,
    /// queue overflow, format-renegotiation), the playback counter
    /// will lag the schedule counter — easy to spot in the periodic log.
    private let counterLock = NSLock()
    private var scheduledBufferCount: Int = 0
    private var playedBackBufferCount: Int = 0

    public init() {
        self.playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000,
                                          channels: 1,
                                          interleaved: false)!
        self.mixer = engine.mainMixerNode
    }

    public func start(deviceUID: String?) async throws {
        if !attached {
            engine.attach(translatedPlayer)
            engine.attach(originalPlayer)
            engine.attach(timePitch)
            attached = true
        }

        // Assign the requested output device before resolving formats so
        // AVAudioEngine can negotiate the mixer→output connection at the
        // device's native sample rate.
        if let uid = deviceUID, let deviceID = audioDeviceID(forUID: uid) {
            var id = deviceID
            AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Wiring: translatedPlayer → timePitch → mixer; originalPlayer → mixer.
        // AVAudioEngine inserts a rate converter between the mixer and the
        // output node automatically when the device's hardware rate differs.
        engine.connect(translatedPlayer, to: timePitch, format: playerFormat)
        engine.connect(timePitch, to: mixer, format: playerFormat)
        engine.connect(originalPlayer, to: mixer, format: playerFormat)

        translatedPlayer.volume = 1.0
        originalPlayer.volume = 0.2
        timePitch.rate = 1.0

        do {
            try engine.start()
        } catch {
            throw NSError(
                domain: "AVAudioOutputMixer",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start audio engine: \(error.localizedDescription)"]
            )
        }
        translatedPlayer.play()
        originalPlayer.play()

        // Diagnostic dump: if `UNISON_DUMP_PLAYBACK_WAV=<path>` is set,
        // install a tap on the timePitch output and stream every render
        // block to a 48 kHz float32 mono WAV. Captures EXACTLY what the
        // mainMixer receives — the same signal whose amplitude envelope
        // we want to verify against the model output. Used to diagnose
        // the user-reported fade on Bluetooth output without needing
        // them to instrument anything themselves.
        startPlaybackDumpIfRequested()

        if pacing == nil {
            pacing = PlaybackPacing(player: translatedPlayer,
                                    timePitch: timePitch,
                                    log: Self.log,
                                    label: "speakers")
        }
        pacing?.reset()
        pacing?.start()
    }

    /// Test-only dump file handle for the pre-mixer tap. Format: float32
    /// mono at 48 kHz. Written incrementally — last 8 bytes of the WAV
    /// header (data chunk size) is patched on stop. If the process is
    /// killed before stop(), the WAV size is the 0xFFFF_FFFF sentinel
    /// and most players will read to EOF anyway.
    private var dumpHandle: FileHandle?
    private var dumpedByteCount: UInt32 = 0

    private func startPlaybackDumpIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["UNISON_DUMP_PLAYBACK_WAV"],
              !path.isEmpty else { return }
        // If we're called from a stop-restart cycle, tap may still be installed.
        timePitch.removeTap(onBus: 0)

        let url = URL(fileURLWithPath: path)
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Self.log.error("UNISON_DUMP_PLAYBACK_WAV — could not open \(path)")
            return
        }
        // Placeholder WAV header (data chunk size = 0xFFFF_FFFF until stop()
        // patches it). 48 kHz mono float32 PCM.
        handle.write(Self.buildWAVHeader(sampleRate: 48_000,
                                         channels: 1,
                                         bitsPerSample: 32,
                                         isFloat: true,
                                         dataSize: 0xFFFF_FFFF))
        dumpHandle = handle
        dumpedByteCount = 0
        Self.log.info("UNISON_DUMP_PLAYBACK_WAV — capturing post-timePitch audio to \(path)")

        let tapFormat = timePitch.outputFormat(forBus: 0)
        timePitch.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let frames = Int(buffer.frameLength)
            guard frames > 0, let ch = buffer.floatChannelData?[0] else { return }
            let bytes = frames * MemoryLayout<Float>.size
            let data = Data(bytes: ch, count: bytes)
            self.appendDumpData(data)
        }
    }

    private func appendDumpData(_ d: Data) {
        guard let handle = dumpHandle else { return }
        handle.write(d)
        dumpedByteCount &+= UInt32(d.count)
    }

    private func closePlaybackDumpIfNeeded() {
        guard let handle = dumpHandle else { return }
        timePitch.removeTap(onBus: 0)
        let dataSize = dumpedByteCount
        let fileSize = dataSize &+ 36
        try? handle.seek(toOffset: 4)
        handle.write(Self.uint32LE(fileSize))
        try? handle.seek(toOffset: 40)
        handle.write(Self.uint32LE(dataSize))
        try? handle.close()
        dumpHandle = nil
        let durationSec = Double(dataSize) / 4.0 / 48_000.0
        Self.log.info("UNISON_DUMP_PLAYBACK_WAV — closed; \(dataSize) bytes (~\(String(format: "%.2f", durationSec))s)")
    }

    // MARK: - WAV header helpers (shared with BlackHole2chPlayer)

    private static func buildWAVHeader(sampleRate: UInt32,
                                       channels: UInt16,
                                       bitsPerSample: UInt16,
                                       isFloat: Bool,
                                       dataSize: UInt32) -> Data {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let fileSize = dataSize &+ 36
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE(16))
        header.append(uint16LE(isFloat ? 3 : 1)) // 1 = PCM int, 3 = IEEE float
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

    public func playTranslated(_ frames: AsyncStream<AudioFrame>) async {
        translatedChunkIndex = 0
        agc.reset()
        resetPlaybackCounters()
        for await frame in frames {
            scheduleTranslated(frame: frame)
        }
    }

    /// Sync helper — Swift 6 strict concurrency disallows `NSLock.lock`
    /// from inside an async function, so the counter reset lives here
    /// and is called from `playTranslated`.
    private func resetPlaybackCounters() {
        counterLock.lock(); defer { counterLock.unlock() }
        scheduledBufferCount = 0
        playedBackBufferCount = 0
    }

    public func playOriginal(_ frames: AsyncStream<AudioFrame>) async {
        for await frame in frames {
            schedule(frame: frame, on: originalPlayer)
        }
    }

    public func setOriginalGain(_ gain: Float) {
        originalPlayer.volume = min(max(gain, 0), 1)
    }

    public func stop() {
        pacing?.stop()
        closePlaybackDumpIfNeeded()
        translatedPlayer.stop()
        originalPlayer.stop()
        engine.stop()
    }

    /// Schedule a translated-track chunk: account for it in the pacing
    /// controller, log periodic RMS for diagnostics, then queue it on
    /// the player. Frames must already be 48k F32 mono — the resampler
    /// is responsible for that, and the cached `playerFormat` is the
    /// same instance used to connect the node graph, so a buffer built
    /// from it is guaranteed accepted.
    private func scheduleTranslated(frame: AudioFrame) {
        // Apply compensating AGC BEFORE building the AVAudioPCMBuffer
        // so the gain ends up baked into the samples we schedule. We
        // chose this over modulating `player.volume` because volume
        // changes are smoothed by AVAudioPlayerNode in a way we can't
        // control, whereas per-sample multiplication is deterministic.
        let frameDurationSec = Double(frame.sampleCount) / Double(frame.sampleRate)
        let (boostedPCM, appliedGain) = agc.apply(pcmF32: frame.pcm,
                                                   frameDurationSec: frameDurationSec)
        let boostedFrame = AudioFrame(pcm: boostedPCM,
                                      sampleRate: frame.sampleRate,
                                      channels: frame.channels,
                                      format: frame.format)
        guard let buf = makeBuffer(from: boostedFrame) else { return }
        if translatedChunkIndex % 10 == 0 {
            let rmsIn = Self.rms(frame)
            let rmsOut = Self.rms(boostedFrame)
            Self.log.debug("[speakers] translated chunk \(translatedChunkIndex) rms_in=\(String(format: "%.5f", rmsIn)) rms_out=\(String(format: "%.5f", rmsOut)) agc_gain=\(String(format: "%.3f", appliedGain)) agc_lt_rms=\(String(format: "%.5f", agc.longTermRMS))")
        }
        translatedChunkIndex += 1
        let frameLength = buf.frameLength
        // Use the explicit `.dataPlayedBack` callback type so we can
        // distinguish "buffer was played by hardware" from "buffer was
        // consumed by the next node" (the default callback). When the
        // engine is reset / queue overflows / sample-rate is
        // renegotiated, a buffer can be CONSUMED without being
        // PLAYED — exactly the scenario we suspect for the "chunk cut
        // off before finishing" bug. Comparing played vs scheduled
        // counts in the log will tell us whether that's happening.
        translatedPlayer.scheduleBuffer(
            buf,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self, weak pacing] _ in
            pacing?.didComplete(samples: AVAudioFramePosition(frameLength))
            if let self {
                self.counterLock.lock()
                self.playedBackBufferCount += 1
                let played = self.playedBackBufferCount
                let scheduled = self.scheduledBufferCount
                self.counterLock.unlock()
                // Every 50 buffers (~20 s at 400 ms chunks) emit a
                // diagnostic comparing scheduled vs played-back. A
                // sustained gap > a few buffers indicates real drops.
                if played % 50 == 0 {
                    let gap = scheduled - played
                    Self.log.info("[speakers] playback counters: scheduled=\(scheduled) played=\(played) gap=\(gap)")
                }
            }
        }
        counterLock.lock()
        scheduledBufferCount += 1
        counterLock.unlock()
        pacing?.didSchedule(samples: AVAudioFramePosition(frameLength))
    }

    private func schedule(frame: AudioFrame, on player: AVAudioPlayerNode) {
        guard let buf = makeBuffer(from: frame) else { return }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    /// Build an `AVAudioPCMBuffer` from `frame` using the cached
    /// `playerFormat`. Returns `nil` (and logs) if the frame's shape
    /// doesn't match — a mismatch indicates the resampler pipeline
    /// upstream is broken, so we surface it loudly rather than silently
    /// scheduling a buffer the player will reject.
    private func makeBuffer(from frame: AudioFrame) -> AVAudioPCMBuffer? {
        guard frame.format == .float32,
              frame.sampleRate == Int(playerFormat.sampleRate),
              frame.channels == Int(playerFormat.channelCount) else {
            Self.log.error("makeBuffer — DROPPING frame: expected 48k F32 mono, got \(frame.sampleRate)Hz \(String(describing: frame.format)) × \(frame.channels)ch")
            return nil
        }
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: frameCount) else { return nil }
        buf.frameLength = frameCount
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(buf.floatChannelData![0], p, frame.pcm.count)
        }
        return buf
    }

    /// Root-mean-square of a float32 PCM frame, used for periodic
    /// diagnostic logging on the translated track.
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
}
