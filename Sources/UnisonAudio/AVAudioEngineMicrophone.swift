import Foundation
import AVFoundation
import CoreAudio
import CoreMedia
import UnisonDomain

/// Microphone capture built on **AVCaptureSession**, not AVAudioEngine.
///
/// **Why not AVAudioEngine.**
/// AVAudioEngine.inputNode on macOS 26 silently refuses to deliver tap
/// callbacks unless the input node is part of a "complete" processing
/// graph — installTap alone is not enough, the node also needs an
/// `engine.connect(input, to: mainMixer, ...)` edge or AUHAL never
/// initializes the input scope. Even *with* that connect, we hit
/// production logs showing engine.isRunning == true and zero tap
/// callbacks for 20 seconds.
///
/// AVCaptureSession is the AVFoundation API designed specifically for
/// capture (the same one QuickTime / Final Cut / Logic use for audio
/// recording). It opens the device, attaches an
/// AVCaptureAudioDataOutput, and delivers `CMSampleBuffer`s via a
/// delegate — no graph, no node connections, no engine.prepare(),
/// no engine.mainMixerNode shenanigans. It works on macOS 14+ and is
/// what every reliable mac audio recorder uses.
///
/// The reference Elixir+Rust impl
/// (https://github.com/LetovKai/call-translator) does the same thing
/// via `cpal`, which on macOS opens CoreAudio AUHAL directly — also
/// bypassing AVAudioEngine. AVCaptureSession is the Swift-native
/// equivalent of that approach.
///
/// **Type name kept for backwards compat.** Composition wires
/// `AVAudioEngineMicrophone()` by name in production. Keeping the
/// type identifier lets us swap the implementation without touching
/// the composition root or other call sites.
public final class AVAudioEngineMicrophone: NSObject, MicrophoneCapture, @unchecked Sendable {
    private static let log = UnisonLog(category: "AVAudioEngineMicrophone")

    private let session = AVCaptureSession()
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    /// Latches once configured + running so a re-entrant `start()`
    /// (orchestrator's reconnect path) resets cleanly via `stop()`
    /// before reconfiguring instead of layering inputs.
    private var running = false
    /// The device UID the active session was started with, replayed when the
    /// session self-heals after a runtime error (re-resolves the device — falls
    /// back to the system default input if the bound one vanished).
    private var currentDeviceUID: String?
    /// Serializes session-lifecycle transitions (start / stop / runtime-error
    /// reconfigure) so the self-heal can't race a stop().
    private let lifecycleLock = NSLock()
    /// Observes `AVCaptureSessionRuntimeError` and restarts capture after a
    /// device disconnect (the AVCaptureSession analogue of the output engines'
    /// `AVAudioEngineConfigurationChange` self-heal).
    private var configObserver: DebouncedNotificationObserver?
    /// Windowed cap on the runtime-error self-heal so a flapping device (one that
    /// re-errors immediately after each restart) can't loop forever. Counted +
    /// reset under `lifecycleLock`.
    private var consecutiveRestarts = 0
    private var lastRestartUptimeNanos: UInt64 = 0
    private static let maxConsecutiveRestarts = 5
    /// Restarts more than `restartWindowNanos` apart are treated as independent
    /// (the device had stabilised), so the counter resets.
    private static let restartWindowNanos: UInt64 = 10_000_000_000  // 10s
    /// Dispatch queue the delegate's `didOutput` callback fires on.
    /// AVCaptureSession requires a serial queue here; we make a
    /// dedicated one so capture work doesn't get queued behind main.
    private let captureQueue = DispatchQueue(label: "com.unison.app.AVAudioEngineMicrophone.capture", qos: .userInitiated)
    /// First-buffer log latch. Per capture session — reset in `start()`
    /// so every session's delivered format lands in the diagnostic, not
    /// just the first one after app launch.
    private let firstBufferLogLock = NSLock()
    private var firstBufferLogged = false

    public override init() {
        super.init()
    }

    public func start(deviceUID: String?) -> AsyncStream<AudioFrame> {
        if running {
            Self.log.info("start() — restarting (previous session left running=true)")
            stop()
        }
        Self.log.info("start(deviceUID=\(deviceUID ?? "<default>"))")
        currentDeviceUID = deviceUID
        firstBufferLogLock.lock()
        firstBufferLogged = false
        firstBufferLogLock.unlock()
        return AsyncStream { [weak self] c in
            guard let self else { c.finish(); return }
            self.lifecycleLock.lock()
            defer { self.lifecycleLock.unlock() }
            self.continuation = c
            self.consecutiveRestarts = 0
            do {
                try self.configure(deviceUID: deviceUID)
                self.session.startRunning()
                self.running = self.session.isRunning
                // Self-heal on a capture runtime error (e.g. the mic device
                // disconnects when Bluetooth headphones drop) — restart on the
                // current default input rather than dying until app relaunch.
                if self.configObserver == nil {
                    self.configObserver = DebouncedNotificationObserver(
                        name: AVCaptureSession.runtimeErrorNotification, object: self.session
                    ) { [weak self] in
                        self?.handleRuntimeError()
                    }
                }
                self.configObserver?.start()
                Self.log.info("start() — session.isRunning=\(self.session.isRunning); awaiting sample buffer delegate callbacks")
            } catch {
                let ns = error as NSError
                Self.log.error("start() — FAILED: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription); no mic frames will flow")
                c.finish()
            }
        }
    }

    public func stop() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        configObserver?.stop()
        running = false
        if session.isRunning { session.stopRunning() }
        // Tear down inputs + outputs so the next start() builds a
        // fresh graph instead of accumulating layers on the same
        // session.
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        continuation?.finish()
        continuation = nil
        Self.log.info("stop() — session stopped, inputs+outputs removed")
    }

    /// Self-heal after `AVCaptureSessionRuntimeError` (typically the input
    /// device disconnected). Re-resolve the device (falls back to the system
    /// default input if the bound one vanished), rebuild, and restart —
    /// keeping the same `continuation` so the orchestrator's frame stream
    /// stays alive. No-op once stopped. Runs on the observer's serial queue;
    /// `lifecycleLock` serializes it with start()/stop().
    private func handleRuntimeError() {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard running else {
            Self.log.info("AVCaptureSessionRuntimeError ignored — mic already stopped")
            return
        }
        // Windowed cap: count consecutive restarts that happen close together
        // (a device re-erroring right after each restart) and give up after the
        // cap so we don't churn forever. A gap longer than the window means the
        // device had stabilised, so the streak resets.
        let now = DispatchTime.now().uptimeNanoseconds
        if now &- lastRestartUptimeNanos > Self.restartWindowNanos { consecutiveRestarts = 0 }
        lastRestartUptimeNanos = now
        guard consecutiveRestarts < Self.maxConsecutiveRestarts else {
            running = false
            Self.log.error("AVCaptureSessionRuntimeError — gave up after \(consecutiveRestarts) restarts within \(Self.restartWindowNanos / 1_000_000_000)s (input device keeps failing); mic stays down until next start()")
            return
        }
        consecutiveRestarts += 1
        Self.log.error("AVCaptureSessionRuntimeError — capture failed (likely input device disconnected); reconfiguring + restarting (attempt \(consecutiveRestarts)/\(Self.maxConsecutiveRestarts))")
        if session.isRunning { session.stopRunning() }
        do {
            try configure(deviceUID: currentDeviceUID)
            session.startRunning()
            running = session.isRunning
            Self.log.info("reconfigure — capture session restarted (isRunning=\(session.isRunning))")
        } catch {
            running = false
            Self.log.error("reconfigure — failed to restart capture session after runtime error: \(String(describing: error)); mic frames stopped")
        }
    }

    private func configure(deviceUID: String?) throws {
        let device = try Self.resolveDevice(uid: deviceUID)
        Self.log.info("configure — using AVCaptureDevice '\(device.localizedName)' uid=\(device.uniqueID)")

        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Idempotent: drop any inputs/outputs from a previous configure so a
        // runtime-error reconfigure rebuilds cleanly instead of layering.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        guard session.canAddInput(input) else {
            throw NSError(domain: "AVAudioEngineMicrophone", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Capture session refused to add input for device \(device.localizedName)"])
        }
        session.addInput(input)

        let audioOutput = AVCaptureAudioDataOutput()
        // No audioSettings override — we accept whatever native format
        // the device delivers (typically 48 kHz float32). The downstream
        // orchestrator resamples to OpenAI's 24 kHz int16 wire format
        // regardless. Setting custom audioSettings on macOS can
        // silently disable the output if the device can't deliver
        // that exact format.
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(audioOutput) else {
            throw NSError(domain: "AVAudioEngineMicrophone", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Capture session refused to add audio output"])
        }
        session.addOutput(audioOutput)
        Self.log.info("configure — input + output added; session ready")
    }

    /// Resolve a CoreAudio device UID to an `AVCaptureDevice`. Falls
    /// back to the system default audio input if the UID doesn't
    /// resolve. Logs loudly so a stale UID (USB device unplugged etc.)
    /// is visible in the diagnostic.
    private static func resolveDevice(uid: String?) throws -> AVCaptureDevice {
        if let uid {
            // First try by uniqueID directly — that's what
            // AVCaptureDevice surfaces and it matches CoreAudio's
            // kAudioDevicePropertyDeviceUID for built-in devices on
            // current macOS. For USB devices the strings sometimes
            // diverge, hence the fallback search below.
            if let d = AVCaptureDevice(uniqueID: uid) {
                return d
            }
            // Linear scan of all audio devices comparing uniqueID
            // exactly. Cheap because the list is short.
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            for d in discovery.devices where d.uniqueID == uid {
                return d
            }
            log.error("resolveDevice — UID '\(uid)' not resolvable via AVCaptureDevice; falling back to system default audio input")
        }
        if let d = AVCaptureDevice.default(for: .audio) {
            return d
        }
        throw NSError(domain: "AVAudioEngineMicrophone", code: -12,
                      userInfo: [NSLocalizedDescriptionKey: "No audio capture device available (system default returned nil)"])
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AVAudioEngineMicrophone: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Pull the PCM bytes out of the sample buffer. AVCaptureSession
        // delivers `CMSampleBuffer` whose CMBlockBuffer holds the
        // contiguous PCM. We copy into a Data so the AsyncStream
        // can hold it past the delegate's call frame.
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return
        }
        let asbd = asbdPtr.pointee
        let sampleRate = Int(asbd.mSampleRate)
        let channels = Int(asbd.mChannelsPerFrame)

        // First-buffer log so the diagnostic shows the actual delivered
        // format. Latched per capture session so the per-frame hot path
        // stays log-free.
        logFirstBufferIfNeeded(sampleRate: sampleRate, channels: channels, asbd: asbd, sampleBuffer: sampleBuffer)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let p = dataPointer, totalLength > 0 else { return }

        // AVCaptureAudioDataOutput on macOS delivers PCM in the
        // device's native format. Most built-in macs use
        // pcmFormatFloat32 non-interleaved; some USB devices give
        // int16. We branch on the ASBD's format flags so the
        // downstream resampler gets the right tag.
        let format: AudioSampleFormat
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            format = .float32
        } else {
            format = .int16
        }

        // Multi-channel handling. Interleaved buffers pass through with
        // their channel tag — `Resampler.toOpenAIWire` averages
        // interleaved channels into mono. Planar (non-interleaved)
        // buffers lay the channel planes back-to-back in the block
        // buffer, which the resampler cannot know about, so we take
        // the first plane (= channel 0) right here.
        let isPlanar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let data: Data
        let outChannels: Int
        if channels > 1, isPlanar {
            data = Data(bytes: p, count: totalLength / channels)
            outChannels = 1
        } else {
            data = Data(bytes: p, count: totalLength)
            outChannels = channels
        }
        let frame = AudioFrame(
            pcm: data,
            sampleRate: sampleRate,
            channels: outChannels,
            format: format
        )
        continuation?.yield(frame)
    }

    private func logFirstBufferIfNeeded(
        sampleRate: Int,
        channels: Int,
        asbd: AudioStreamBasicDescription,
        sampleBuffer: CMSampleBuffer
    ) {
        firstBufferLogLock.lock()
        let shouldLog = !firstBufferLogged
        if shouldLog { firstBufferLogged = true }
        firstBufferLogLock.unlock()
        guard shouldLog else { return }
        let nSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        Self.log.info("first sample buffer — sampleRate=\(sampleRate)Hz channels=\(channels) format=\(isFloat ? "float32" : "int16") frames=\(nSamples) bitsPerChan=\(asbd.mBitsPerChannel)")
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
