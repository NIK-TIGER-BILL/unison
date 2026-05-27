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

    /// `var` — recreated on every `start()` call. Reusing the same
    /// `AVAudioEngine` instance across stop/start cycles leaves stale
    /// graph state (the `inputNode → mainMixerNode` connection
    /// installed during the previous session) that hangs the second
    /// `installTap` call on macOS 26. Allocating a fresh engine
    /// sidesteps the issue entirely — there's no observable downside,
    /// `AVAudioEngine()` is cheap (no I/O until `prepare`/`start`).
    private var engine = AVAudioEngine()
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
    /// Watchdog task that fires `log.error` if the first tap callback
    /// hasn't arrived within 5 s of `engine.start()`. Critical
    /// diagnostic for the "BlackHole sees zero frames" failure mode —
    /// without this, the only signal is the absence of a log line,
    /// which is invisible to users grep-ing for errors.
    private var tapWatchdog: Task<Void, Never>?

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
        // Fresh engine per session. Reusing the previous one (after
        // `engine.stop()` + `removeTap()` in `stop()`) leaves the
        // `inputNode → mainMixerNode` connection from the previous
        // session in the graph, which hangs the next `installTap`
        // call on macOS 26 — the user-visible symptom is "Start works
        // the first time but the second Start sticks in `connecting`
        // and the timer never starts".
        engine = AVAudioEngine()
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
        tapWatchdog?.cancel()
        tapWatchdog = nil
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
        // Log the device's *native* format BEFORE binding. AVAudioEngine's
        // inputNode.outputFormat(forBus: 0) reports the engine's internal
        // negotiated format, which can silently differ from the actual
        // device's stream format on macOS 26 — e.g. BlackHole 16ch's
        // physical format may be 48 kHz × 16ch but the engine reports
        // 16 kHz × 1ch because AUHAL fell back. Logging both lets us
        // diagnose the mismatch.
        if let native = Self.queryDeviceNativeFormat(deviceID: deviceID, scope: kAudioObjectPropertyScopeInput) {
            Self.log.info("bindInput — BlackHole 16ch native input format: \(native.sampleRate)Hz × \(native.channels)ch (\(native.format))")
        } else {
            Self.log.error("bindInput — could not query native input format for BlackHole 16ch (id=\(deviceID))")
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

    /// Query CoreAudio for a device's native (physical) stream format,
    /// bypassing whatever AVAudioEngine negotiated. Returns nil on
    /// failure. Logging both this *and* `inputNode.outputFormat(forBus:0)`
    /// surfaces silent format-fallback failures.
    private static func queryDeviceNativeFormat(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> (sampleRate: Double, channels: UInt32, format: String)? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyPhysicalFormat,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        // PhysicalFormat lives on the device's streams. Find first stream.
        var streamsAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var streamsSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &streamsAddr, 0, nil, &streamsSize) == noErr,
              streamsSize > 0 else { return nil }
        let streamCount = Int(streamsSize) / MemoryLayout<AudioStreamID>.size
        var streams = [AudioStreamID](repeating: 0, count: streamCount)
        guard AudioObjectGetPropertyData(deviceID, &streamsAddr, 0, nil, &streamsSize, &streams) == noErr,
              let firstStream = streams.first else { return nil }

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(firstStream, &address, 0, nil, &size, &asbd) == noErr else {
            return nil
        }
        let formatName: String
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            formatName = "float\(asbd.mBitsPerChannel)"
        } else {
            formatName = "int\(asbd.mBitsPerChannel)"
        }
        return (asbd.mSampleRate, asbd.mChannelsPerFrame, formatName)
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
        // CRITICAL: install the tap BEFORE wiring inputNode →
        // mainMixer + engine.prepare. The mic fix in commit 6f56bd0
        // had this exact sequence; reversing it (connect first, then
        // installTap) hangs the `installTap` call indefinitely on
        // macOS 26 — verified empirically by stepping log lines
        // through this path. The connect+prepare lines below complete
        // the graph so AUHAL initializes the input scope; the tap
        // is what actually delivers PCM frames once that happens.
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
        Self.log.info("startTap — tap installed (bufferSize=1024 frames)")

        // Complete the graph: connect inputNode → mainMixer (silenced
        // via outputVolume=0 above) so AUHAL initializes the input
        // scope and the tap actually fires. macOS 26 silently drops
        // tap callbacks otherwise — see the engine.connect doc-comment
        // upstream for the full failure mode.
        engine.connect(input, to: mainMixer, format: format)
        Self.log.info("startTap — connected inputNode → mainMixerNode (volume=0, no loopback)")

        engine.prepare()
        Self.log.info("startTap — calling engine.start()")
        try engine.start()
        Self.log.info("startTap — engine.start() returned; isRunning=\(engine.isRunning)")
        armTapWatchdog()
    }

    /// Watchdog that fires `log.error` if no tap callback has arrived
    /// within 5 s of `engine.start()`. The 5 s budget is generous —
    /// in a healthy run the first callback usually arrives within
    /// 50–200 ms.
    private func armTapWatchdog() {
        tapWatchdog?.cancel()
        tapWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            if !self.loggedFirstFrame {
                Self.log.error("tap watchdog — NO tap callback received in 5 seconds despite engine.isRunning=\(self.engine.isRunning). BlackHole 16ch is not delivering audio. Most common causes: (1) call app (Zoom/Meet) isn't actually routing audio to BlackHole 16ch even if it claims to in settings, (2) macOS Audio MIDI Setup has BlackHole 16ch configured with an unusable stream format, (3) another process is holding exclusive access to the device.")
            }
        }
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
