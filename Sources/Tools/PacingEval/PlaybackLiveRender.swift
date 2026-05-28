import Foundation
import AVFoundation
import CoreAudio

/// Runs an audio file through the production playback chain using a
/// **live** `AVAudioEngine` — i.e. driven by the system audio device's
/// real-time render clock, the same way production runs. Captures the
/// post-mixer audio via an `installTap` and writes it to a WAV.
///
/// Difference from `PlaybackOfflineRender`:
/// - Live mode → engine output goes to the current default audio
///   device (real device, real clock). Volume is muted via player so
///   nothing is audible.
/// - The render clock comes from the device, which is where the
///   user-reported fade is hypothesized to live (BT driver clock
///   drift compensation, sample-rate negotiation, etc.).
///
/// Caveats:
/// - The output device determines the clock. If the user reports fade
///   on Bluetooth and this harness runs against wired headphones, we
///   may not reproduce the fade — but a clean result still narrows
///   the suspect list.
/// - Player volume is set to 0 so we don't blast audio at the user
///   running this. The tap still captures the post-mixer signal
///   pre-volume-scaling (verified empirically against the offline
///   render).
struct PlaybackLiveRender {
    let inputPCM24kInt16: Data
    let renderDurationSec: Double
    let useTimePitch: Bool

    struct Output {
        /// Captured post-mixer PCM as float32 mono at the engine's
        /// hardware sample rate (typically 48 kHz). Convert to int16
        /// 24 kHz for direct comparison with model-output WAV.
        let capturedFloatPCM: Data
        let captureSampleRate: Double
        let renderedSec: Double
    }

    func render() async throws -> Output {
        let in24k = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: 24_000,
                                  channels: 1,
                                  interleaved: true)!
        let playerFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000,
                                         channels: 1,
                                         interleaved: false)!

        let inputFrames = inputPCM24kInt16.count / 2
        guard let in24 = AVAudioPCMBuffer(pcmFormat: in24k, frameCapacity: AVAudioFrameCount(inputFrames)) else {
            throw PacingEvalError.audioRead("alloc in24 buffer")
        }
        in24.frameLength = AVAudioFrameCount(inputFrames)
        inputPCM24kInt16.withUnsafeBytes { raw in
            memcpy(in24.int16ChannelData![0], raw.baseAddress!, inputPCM24kInt16.count)
        }
        let upsampledFrames = AVAudioFrameCount(Double(inputFrames) * 48_000.0 / 24_000.0)
        guard let in48 = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: upsampledFrames) else {
            throw PacingEvalError.audioRead("alloc in48 buffer")
        }
        let converter = AVAudioConverter(from: in24k, to: playerFormat)!
        let inputState = LiveConvState(buffer: in24)
        var convError: NSError?
        converter.convert(to: in48, error: &convError) { _, statusPtr in
            if let b = inputState.takeOnce() {
                statusPtr.pointee = .haveData
                return b
            }
            statusPtr.pointee = .endOfStream
            return nil
        }
        if let convError {
            throw PacingEvalError.audioRead("converter: \(convError.localizedDescription)")
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(player)
        if useTimePitch {
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: playerFormat)
            engine.connect(timePitch, to: engine.mainMixerNode, format: playerFormat)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        }

        // Mute the engine's final output (mainMixer → outputNode) so
        // this CLI tool doesn't blast translation audio at whoever
        // runs it. We tap UPSTREAM of mainMixer so the capture isn't
        // affected by this volume.
        engine.mainMixerNode.outputVolume = 0

        // Capture box for the tap callback (renders on the audio
        // queue, not the main thread). Tap the LAST node before
        // mainMixer (timePitch when in chain, otherwise the player
        // directly) so the capture isn't silenced by the mainMixer
        // outputVolume mute we just set.
        let captureBox = TapCaptureBox()
        let captureNode: AVAudioNode = useTimePitch ? timePitch : player
        let captureFormat = captureNode.outputFormat(forBus: 0)
        captureNode.installTap(onBus: 0, bufferSize: 4096, format: captureFormat) { buffer, _ in
            let frames = Int(buffer.frameLength)
            guard frames > 0, let ch = buffer.floatChannelData?[0] else { return }
            let bytes = frames * MemoryLayout<Float>.size
            let data = Data(bytes: ch, count: bytes)
            captureBox.append(data)
        }

        // Prepare + start the engine (live mode — driven by device clock).
        engine.prepare()
        try engine.start()
        player.play()

        // Schedule the entire input as one buffer. In production we
        // schedule each ~400ms chunk separately as it arrives, but the
        // node-graph processing is identical either way at rate=1.0.
        // We schedule everything upfront so the test isolates "long-
        // running live render" from any chunk-arrival-timing effects.
        player.scheduleBuffer(in48, completionHandler: nil)

        // Let the engine run for renderDurationSec wall-clock seconds.
        // The render thread is driven by the audio device's clock —
        // this is precisely the part of production we couldn't
        // reproduce in the offline renderer.
        try await Task.sleep(nanoseconds: UInt64(renderDurationSec * 1_000_000_000))

        captureNode.removeTap(onBus: 0)
        engine.stop()

        return Output(
            capturedFloatPCM: captureBox.snapshot(),
            captureSampleRate: captureFormat.sampleRate,
            renderedSec: renderDurationSec
        )
    }
}

/// Thread-safe capture buffer for the AVAudio tap callback.
private final class TapCaptureBox: @unchecked Sendable {
    private var buf = Data()
    private let lock = NSLock()
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(d)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return buf
    }
}

private final class LiveConvState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let lock = NSLock()
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func takeOnce() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        let b = buffer
        buffer = nil
        return b
    }
}
