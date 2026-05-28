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

        if pacing == nil {
            pacing = PlaybackPacing(player: translatedPlayer,
                                    timePitch: timePitch,
                                    log: Self.log,
                                    label: "speakers")
        }
        pacing?.reset()
        pacing?.start()
    }

    public func playTranslated(_ frames: AsyncStream<AudioFrame>) async {
        translatedChunkIndex = 0
        for await frame in frames {
            scheduleTranslated(frame: frame)
        }
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
        guard let buf = makeBuffer(from: frame) else { return }
        if translatedChunkIndex % 10 == 0 {
            let rms = Self.rms(frame)
            Self.log.debug("[speakers] translated chunk \(translatedChunkIndex) rms=\(String(format: "%.5f", rms))")
        }
        translatedChunkIndex += 1
        let frameLength = buf.frameLength
        // Capture frameLength + a weak pacing ref. Completion fires on a
        // CoreAudio render thread; PlaybackPacing.didComplete is lock-
        // protected so the race against tick() is safe.
        translatedPlayer.scheduleBuffer(buf) { [weak pacing] in
            pacing?.didComplete(samples: AVAudioFramePosition(frameLength))
        }
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
