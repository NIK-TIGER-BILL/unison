import Foundation
import AVFoundation
import CoreAudio
import UnisonDomain

public final class AVAudioEngineMicrophone: MicrophoneCapture, @unchecked Sendable {
    /// Diagnostic logger. Every step of binding + engine.start gets a
    /// line here so a "Микрофон не подаёт сигнал" report can be
    /// triaged from the file log alone — without this the failure
    /// path inside the AsyncStream closure swallows errors silently
    /// (we only have `c.finish()` to signal upstream).
    private static let log = UnisonLog(category: "AVAudioEngineMicrophone")

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    /// Latches while a tap is installed on `engine.inputNode`. Apple
    /// docs: "Installing a tap with the same format throws an
    /// exception" — and `AVAudioNode` exceptions are Obj-C, so they
    /// kill the process. `wireOutgoingPipeline` in the orchestrator
    /// calls `start()` on every reconnect, so without this guard a
    /// transient WS drop mid-call would CRASH the app on the second
    /// installTap. Idempotency keeps us safe.
    private var started = false

    public init() {}

    public func start(deviceUID: String?) -> AsyncStream<AudioFrame> {
        // If a previous start() didn't go through a stop() (e.g. the
        // orchestrator's reconnect path re-wires the pipeline without
        // tearing down the mic), reset so the new installTap doesn't
        // throw against the lingering one. The previous AsyncStream
        // consumer was cancelled by the orchestrator before this
        // call, so finishing it here is harmless.
        if started {
            Self.log.info("start() — restarting (previous session left engine in `started=true`)")
            stop()
        }
        Self.log.info("start(deviceUID=\(deviceUID ?? "<default>"))")
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.continuation = c
            do {
                try self.bindInputDevice(uid: deviceUID)
                try self.startEngine()
                self.started = true
                Self.log.info("start() — bind + engine.start successful; awaiting tap callbacks")
            } catch {
                let ns = error as NSError
                Self.log.error("start() — FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) → continuation finished, no mic frames will flow")
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

    private func bindInputDevice(uid: String?) throws {
        guard let uid else {
            Self.log.info("bindInputDevice — no UID; engine will use system default input")
            return
        }
        guard let deviceID = audioDeviceID(forUID: uid) else {
            // Not throwing — falling back to default is the lesser
            // evil. But surface it loudly: this is the most likely
            // cause of "I picked device X but nothing happens" —
            // the stored UID from a previous launch may no longer
            // resolve (USB device unplugged, etc.).
            Self.log.error("bindInputDevice — UID '\(uid)' not found in CoreAudio device list; engine will fall back to system default. Re-pick the device in Settings if this isn't intended.")
            return
        }
        Self.log.info("bindInputDevice — resolved UID '\(uid)' to deviceID=\(deviceID); binding")
        var id = deviceID
        let status = AudioUnitSetProperty(
            engine.inputNode.audioUnit!,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &id, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Self.log.error("bindInputDevice — AudioUnitSetProperty(CurrentDevice) returned status=\(status); throwing")
            throw NSError(domain: "AVAudioEngineMicrophone", code: Int(status))
        }
        Self.log.info("bindInputDevice — bound successfully")
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        Self.log.info("startEngine — inputNode format: \(format.sampleRate)Hz × \(format.channelCount)ch \(String(describing: format.commonFormat))")

        if format.sampleRate == 0 || format.channelCount == 0 {
            // This is a real-world symptom on macOS when an input
            // device is bound but the engine hasn't established a
            // valid stream for it yet — `installTap` will succeed
            // but the callback never fires (no audio to deliver).
            // Surfacing it explicitly so the diagnostic shows the
            // root cause instead of just "no mic frames".
            Self.log.error("startEngine — degenerate input format (sampleRate=\(format.sampleRate), channels=\(format.channelCount)); the tap will install but never fire. Permission revoked or device unavailable.")
        }

        var tapInvocationCount = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            tapInvocationCount += 1
            // Log the first 3 tap invocations so we can see frames
            // actually arriving + frame size. After that the per-frame
            // RMS logging in the orchestrator's pipeline takes over.
            if tapInvocationCount <= 3 {
                Self.log.info("tap callback #\(tapInvocationCount) — frameLength=\(buffer.frameLength) (= \(Int(Double(buffer.frameLength) * 1000 / format.sampleRate))ms at \(format.sampleRate)Hz)")
            }
            guard let cd = buffer.floatChannelData else {
                if tapInvocationCount <= 3 {
                    Self.log.error("tap callback — buffer.floatChannelData is nil; cannot extract PCM")
                }
                return
            }
            let n = Int(buffer.frameLength)
            let byteCount = n * MemoryLayout<Float>.size
            var data = Data(count: byteCount)
            data.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Float.self).baseAddress!
                memcpy(p, cd[0], byteCount)
            }
            let frame = AudioFrame(
                pcm: data,
                sampleRate: Int(format.sampleRate),
                channels: Int(format.channelCount),
                format: .float32
            )
            self.continuation?.yield(frame)
        }

        // CRITICAL: on macOS 26, the input subsystem doesn't actually
        // start delivering audio to taps unless the inputNode is part
        // of the engine's processing graph. A standalone `installTap`
        // — without a downstream connection — leaves the input node
        // "idle from the engine's POV": `engine.start()` returns,
        // `isRunning == true`, but the underlying CoreAudio AUHAL
        // never gets an `AudioUnitInitialize` for input → no audio
        // ever flows. The fix is to connect inputNode → mainMixerNode
        // so the engine has a complete graph, and silence the mixer
        // so nothing actually plays through the speakers as
        // monitoring loopback.
        //
        // This matches Apple's `AVAudioEngine` sample code and the
        // pattern other macOS recording apps use. It was missing here
        // because the original implementation only used a tap and
        // happened to work on earlier macOS revisions.
        let mainMixer = engine.mainMixerNode
        mainMixer.outputVolume = 0  // mute the loopback BEFORE connecting
        engine.connect(input, to: mainMixer, format: format)
        Self.log.info("startEngine — connected inputNode → mainMixerNode (volume=0, no loopback)")

        // `prepare()` walks the graph and pre-allocates AUHAL state.
        // Optional in theory but on macOS 26 it noticeably reduces
        // the chance of the first tap-callback being delayed by
        // hundreds of ms while the engine cold-starts.
        engine.prepare()

        Self.log.info("startEngine — tap installed (bufferSize=1024 frames); calling engine.start()")
        do {
            try engine.start()
        } catch {
            let ns = error as NSError
            Self.log.error("startEngine — engine.start() threw: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
            throw error
        }
        Self.log.info("startEngine — engine.start() returned; running=\(engine.isRunning)")
    }
}

// Shared helper for device-UID → AudioDeviceID lookup, used by all audio components in this module.
internal func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
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
        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, ptr)
        }
        if status == noErr, let s = cfStr as String?, s == uid { return id }
    }
    return nil
}
