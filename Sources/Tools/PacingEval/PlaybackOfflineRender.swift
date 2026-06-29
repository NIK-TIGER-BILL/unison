import Foundation
import AVFoundation

/// Runs an audio file through the production playback chain
/// (`AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer`) in
/// `AVAudioEngine.ManualRenderingMode.offline` — no real audio device,
/// no hardware clock, no Bluetooth. Captures the post-mixer PCM into a
/// buffer so we can compare the input amplitude envelope against the
/// engine's output.
///
/// Purpose: isolate "does the AVAudioEngine playback chain itself
/// introduce a fade-out over a long continuous session?" from device-
/// /driver-specific causes. If the offline render fades, we've
/// pinned the bug to the AVAudio* nodes. If it stays flat, the fade
/// in production must be downstream (engine→device, BT driver, etc.).
struct PlaybackOfflineRender {
    /// 24kHz int16 mono input. Will be upsampled to 48kHz F32 (matching
    /// production resampler output) before scheduling.
    let inputPCM24kInt16: Data
    /// How long to render in audio-seconds. Pass `inputPCM24kInt16.count
    /// / 2 / 24000` to cover the whole input.
    let renderDurationSec: Double
    /// Whether to insert AVAudioUnitTimePitch in the chain.
    /// Use `false` to A/B "is TimePitch the culprit".
    let useTimePitch: Bool

    /// Output: post-mainMixer PCM in float32 mono 48kHz format. Save
    /// via WAVWriter (the float32 WAV writer would need a separate
    /// helper, but we convert back to int16 24k for direct apples-to-
    /// apples comparison with the input WAV).
    struct Output {
        let pcmInt16_24k: Data
        let renderedFrames: Int
    }

    func render() throws -> Output {
        let in24k = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: 24_000,
                                  channels: 1,
                                  interleaved: true)!
        let f48k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: 48_000,
                                 channels: 1,
                                 interleaved: false)!

        // Build the input buffer at 24kHz int16, then convert to 48k F32
        // — mirroring what `Resampler.fromWire` does in production.
        let inputFrames = inputPCM24kInt16.count / 2
        guard let in24 = AVAudioPCMBuffer(pcmFormat: in24k, frameCapacity: AVAudioFrameCount(inputFrames)) else {
            throw PacingEvalError.audioRead("alloc in24 buffer")
        }
        in24.frameLength = AVAudioFrameCount(inputFrames)
        inputPCM24kInt16.withUnsafeBytes { raw in
            _ = memcpy(in24.int16ChannelData![0], raw.baseAddress!, inputPCM24kInt16.count)
        }
        let upsampledFrames = AVAudioFrameCount(Double(inputFrames) * 48_000.0 / 24_000.0)
        guard let in48 = AVAudioPCMBuffer(pcmFormat: f48k, frameCapacity: upsampledFrames) else {
            throw PacingEvalError.audioRead("alloc in48 buffer")
        }
        let converter = AVAudioConverter(from: in24k, to: f48k)!
        let inputState = OfflineConvState(buffer: in24)
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

        // Build the same node graph the production AVAudioOutputMixer uses.
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(player)
        if useTimePitch {
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: f48k)
            engine.connect(timePitch, to: engine.mainMixerNode, format: f48k)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: f48k)
        }

        // Switch the engine to offline manual rendering BEFORE start().
        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: f48k, maximumFrameCount: maxFrames)
        try engine.start()
        player.play()

        // Schedule the entire input as one chunk. The player consumes it
        // at the engine's clock — exactly mimics production where pacing
        // rate stays at 1.0 in 95+% of ticks.
        player.scheduleBuffer(in48, completionHandler: nil)

        let renderBuf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                         frameCapacity: maxFrames)!
        let totalRenderFrames = AVAudioFramePosition(renderDurationSec * 48_000.0)
        var renderedTotal: AVAudioFramePosition = 0
        var collected = Data()  // float32 LE samples at 48kHz mono

        while renderedTotal < totalRenderFrames {
            let frames = AVAudioFrameCount(min(Int(maxFrames),
                                               Int(totalRenderFrames - renderedTotal)))
            let status = try engine.renderOffline(frames, to: renderBuf)
            switch status {
            case .success:
                let renderedFrames = Int(renderBuf.frameLength)
                let bytes = renderedFrames * MemoryLayout<Float>.size
                let chunk = Data(bytes: renderBuf.floatChannelData![0], count: bytes)
                collected.append(chunk)
                renderedTotal += AVAudioFramePosition(renderedFrames)
            case .insufficientDataFromInputNode:
                // No more scheduled input; the engine will emit silence
                // from here on. We're done collecting useful output.
                break
            case .cannotDoInCurrentContext:
                throw PacingEvalError.audioRead("renderOffline cannotDoInCurrentContext")
            case .error:
                throw PacingEvalError.audioRead("renderOffline returned error")
            @unknown default:
                break
            }
        }

        engine.stop()

        // Downsample the 48kHz float32 capture to 24kHz int16 so the
        // RMS comparison against the input WAV is apples-to-apples.
        let outF32 = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000,
                                   channels: 1,
                                   interleaved: false)!
        let outI16 = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                   sampleRate: 24_000,
                                   channels: 1,
                                   interleaved: true)!
        let outFrames = AVAudioFrameCount(collected.count / MemoryLayout<Float>.size)
        let f32buf = AVAudioPCMBuffer(pcmFormat: outF32, frameCapacity: outFrames)!
        f32buf.frameLength = outFrames
        collected.withUnsafeBytes { raw in
            _ = memcpy(f32buf.floatChannelData![0], raw.baseAddress!, collected.count)
        }
        let downsampledFrames = AVAudioFrameCount(Double(outFrames) * 24_000.0 / 48_000.0) + 64
        let i16buf = AVAudioPCMBuffer(pcmFormat: outI16, frameCapacity: downsampledFrames)!
        let backConv = AVAudioConverter(from: outF32, to: outI16)!
        let outState = OfflineConvState(buffer: f32buf)
        var convError2: NSError?
        backConv.convert(to: i16buf, error: &convError2) { _, statusPtr in
            if let b = outState.takeOnce() {
                statusPtr.pointee = .haveData
                return b
            }
            statusPtr.pointee = .endOfStream
            return nil
        }
        if let convError2 {
            throw PacingEvalError.audioRead("output converter: \(convError2.localizedDescription)")
        }

        let outBytes = Int(i16buf.frameLength) * 2
        var outData = Data(count: outBytes)
        outData.withUnsafeMutableBytes { dst in
            _ = memcpy(dst.baseAddress!, i16buf.int16ChannelData![0], outBytes)
        }
        return Output(pcmInt16_24k: outData, renderedFrames: Int(renderedTotal))
    }
}

/// Same one-shot-then-EOS wrapper used in AudioReader; kept local
/// here to avoid leaking it as cross-module public surface.
private final class OfflineConvState: @unchecked Sendable {
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
