import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class BlackHoleSinkCapture: PeerAudioCapture, @unchecked Sendable {
    /// Diagnostic logger. Without this class logging anything, a silent
    /// "no peer transcript / no muffled original" failure (the canonical
    /// macOS 26 AVAudioEngine.inputNode regression) is invisible in the
    /// diagnostic dump. Mirrors to `~/Library/Logs/Unison/unison.log` —
    /// see `UnisonLog`.
    private static let log = UnisonLog(category: "BlackHoleSinkCapture")

    private let engine = AVAudioEngine()
    private let registry: CoreAudioDeviceRegistry
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    /// Same idempotency latch as `AVAudioEngineMicrophone.started`.
    /// Orchestrator's `wireIncomingPipeline` re-runs on every peer-
    /// stream reconnect, calling `start()` without first calling
    /// `stop()`. Without this guard the second installTap throws an
    /// Obj-C exception and crashes the app.
    private var started = false
    /// First-callback latch — fires `log.info` exactly once per
    /// `start()` so the diagnostic confirms BlackHole 16ch is actually
    /// delivering frames (i.e. the graph-orphan macOS 26 regression
    /// is NOT happening on this run). Subsequent callbacks stay
    /// log-free.
    private var loggedFirstFrame = false

    public init(registry: CoreAudioDeviceRegistry) {
        self.registry = registry
    }

    public func start() -> AsyncStream<AudioFrame> {
        // Reset if a previous start didn't go through a paired stop.
        // See `started` doc-comment for why this matters under
        // reconnect.
        if started {
            Self.log.info("start() — previous session left started=true; calling stop() first")
            stop()
        }
        Self.log.info("start() — opening BlackHole 16ch capture")
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                guard let bh16 = self.registry.findBlackHole16ch() else {
                    Self.log.error("start() — BlackHole 16ch device not found in registry; no peer frames will flow")
                    c.finish()
                    return
                }
                Self.log.info("start() — found BlackHole 16ch uid=\(bh16.uid)")
                try self.bindInput(uid: bh16.uid)
                try self.startTap()
                self.started = true
                self.loggedFirstFrame = false
                Self.log.info("start() — capture engine running; awaiting first tap callback")
            } catch {
                let ns = error as NSError
                Self.log.error("start() — FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription); no peer frames will flow")
                c.finish()
            }
        }
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
        started = false
        Self.log.info("stop() — engine stopped, tap removed")
    }

    private func bindInput(uid: String) throws {
        guard let deviceID = audioDeviceID(forUID: uid) else {
            Self.log.error("bindInput — audioDeviceID(forUID: \(uid)) returned nil")
            throw NSError(domain: "BlackHoleSinkCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not resolve AudioDeviceID for BlackHole 16ch (uid=\(uid))"])
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Self.log.error("bindInput — AudioUnitSetProperty(CurrentDevice → \(uid)) failed status=\(status); engine will fall back to system default input")
            throw NSError(domain: "BlackHoleSinkCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "AudioUnitSetProperty(CurrentDevice) failed: status=\(status)"])
        }
        Self.log.info("bindInput — input device bound to BlackHole 16ch (id=\(deviceID))")
    }

    private func startTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.log.info("startTap — inputNode format: \(format.sampleRate)Hz × \(format.channelCount)ch")

        // CRITICAL: on macOS 26 the input subsystem inside AVAudioEngine
        // doesn't deliver audio to taps unless the inputNode is part of
        // the engine's processing graph. A standalone `installTap` —
        // with no `engine.connect(inputNode, to:..., format:)` — leaves
        // the input node "graph-orphaned": `engine.start()` returns
        // and `isRunning == true`, but the underlying AUHAL never gets
        // `AudioUnitInitialize` on the input scope, so no PCM ever
        // flows. The tap callback never fires.
        //
        // The fix is to connect inputNode → mainMixerNode so the
        // engine has a complete graph, and silence the mixer so the
        // BlackHole 16ch signal is NOT echoed through the default
        // output device as monitoring loopback (which would otherwise
        // double-play the peer's voice into the user's ears).
        //
        // This mirrors the fix applied to `AVAudioEngineMicrophone` in
        // commit `6f56bd0` ("fix(audio): connect inputNode → mainMixer
        // so AVAudioEngine tap actually fires"). The microphone path
        // was subsequently rewritten on AVCaptureSession (commit
        // `944c8ea`), but the peer capture stayed on AVAudioEngine —
        // and inherited the macOS 26 graph-orphan regression because
        // the same engine-connect fix was never replicated here.
        let mainMixer = engine.mainMixerNode
        mainMixer.outputVolume = 0  // mute the loopback BEFORE connecting
        engine.connect(input, to: mainMixer, format: format)
        Self.log.info("startTap — connected inputNode → mainMixerNode (volume=0, no loopback)")

        // `prepare()` walks the graph and pre-allocates AUHAL state.
        // Optional in theory but on macOS 26 it noticeably reduces
        // the chance of the first tap callback being delayed by
        // hundreds of ms while the engine cold-starts.
        engine.prepare()

        // Buffer size matches `AVAudioEngineMicrophone` from the same
        // era (1024 frames ≈ 21ms at 48kHz). Apple's docs hint at
        // smaller buffers being more reliable for first-callback
        // delivery on macOS 26. Still well inside the OpenAI batcher's
        // 100ms expectation.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, let cd = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let byteCount = n * MemoryLayout<Float>.size
            var data = Data(count: byteCount)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Float.self).baseAddress!
                memcpy(p, cd[0], byteCount)
            }
            self.logFirstFrameIfNeeded(buffer: buffer, format: format)
            let frame = AudioFrame(
                pcm: data,
                sampleRate: Int(format.sampleRate),
                channels: 1,
                format: .float32
            )
            self.continuation?.yield(frame)
        }
        Self.log.info("startTap — tap installed (bufferSize=1024 frames); calling engine.start()")
        try engine.start()
        Self.log.info("startTap — engine.start() returned; isRunning=\(engine.isRunning)")
    }

    /// First-frame diagnostic. Computes RMS over the first 1024 samples
    /// so the log shows whether the peer audio is hot (real call audio
    /// flowing through BlackHole) or silent (Zoom not routed to
    /// BlackHole 16ch, or call muted). Critical for distinguishing
    /// "graph-orphan regression" (zero callbacks) from "callbacks
    /// fire but BlackHole sees no audio" (Zoom routing problem).
    private func logFirstFrameIfNeeded(buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard !loggedFirstFrame, let cd = buffer.floatChannelData else { return }
        loggedFirstFrame = true
        let n = Int(buffer.frameLength)
        var sumSquares: Float = 0
        let p = cd[0]
        for i in 0..<n { sumSquares += p[i] * p[i] }
        let rms = n > 0 ? (sumSquares / Float(n)).squareRoot() : 0
        Self.log.info("first tap callback — \(format.sampleRate)Hz × \(format.channelCount)ch float32, frames=\(n), rms=\(String(format: "%.5f", rms))")
        if rms < 0.0005 {
            Self.log.error("first tap callback — RMS \(String(format: "%.5f", rms)) is near-silent. BlackHole 16ch is delivering frames but they're silent; check that the call app (Zoom, Meet, etc.) is using BlackHole 16ch as its speaker output.")
        }
    }
}
