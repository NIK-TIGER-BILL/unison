import Foundation
import AVFoundation
import UnisonDomain

/// Holds one-shot input state for an AVAudioConverter input callback.
/// Mutating the closure-captured state directly is rejected under strict
/// concurrency; wrapping it in a class with a locked accessor keeps the
/// closure non-mutating while preserving the "feed input once, then EOS"
/// pattern that AVAudioConverter requires when draining its internal tail.
private final class ConverterInputState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let lock = NSLock()

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        let b = buffer
        buffer = nil
        return b
    }
}

public enum Resampler {
    public static func toOpenAIWire(_ frame: AudioFrame) -> AudioFrame {
        if frame.sampleRate == 24_000, frame.format == .int16 { return frame }
        let f32_24k = resampleFloat32(frame, targetSampleRate: 24_000)
        return convertFloat32ToInt16(f32_24k)
    }

    public static func fromOpenAIWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        let f32 = convertInt16ToFloat32(frame)
        return resampleFloat32(f32, targetSampleRate: targetSampleRate)
    }

    // MARK: - Helpers

    private static func resampleFloat32(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        guard frame.format == .float32 else {
            fatalError("resampleFloat32 expects .float32 input")
        }
        if frame.sampleRate == targetSampleRate { return frame }
        // Empty frames slip through from AVAudioEngine on cold start of the mic
        // capture (the engine emits a 0-length buffer before the first real
        // chunk). AVAudioPCMBuffer(frameCapacity: 0) returns nil, so the
        // force-unwrap below crashed with SIGTRAP. Pass empties through with a
        // re-tagged sample rate so the wire-format step doesn't see a stale rate.
        if frame.sampleCount == 0 {
            return AudioFrame(pcm: Data(), sampleRate: targetSampleRate,
                              channels: frame.channels, format: .float32)
        }

        let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Double(frame.sampleRate),
                                   channels: AVAudioChannelCount(frame.channels),
                                   interleaved: false)!
        let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: Double(targetSampleRate),
                                   channels: AVAudioChannelCount(frame.channels),
                                   interleaved: false)!

        let srcFrames = AVAudioFrameCount(frame.sampleCount)
        let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: srcFrames)!
        srcBuf.frameLength = srcFrames
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(srcBuf.floatChannelData![0], p, frame.pcm.count)
        }

        // Expected exact output frame count by sample-rate ratio.
        let targetFrames = Int((Double(frame.sampleCount) * Double(targetSampleRate)) / Double(frame.sampleRate))
        let bytesPerFloat = MemoryLayout<Float>.size

        let converter = AVAudioConverter(from: srcFmt, to: dstFmt)!

        var accumulated = Data()
        accumulated.reserveCapacity(targetFrames * bytesPerFloat)

        // Shared input-state holder lets the AVAudioConverter input callback
        // remain a non-mutating Sendable closure (Swift 6 strict concurrency).
        let inputState = ConverterInputState(buffer: srcBuf)

        while accumulated.count < targetFrames * bytesPerFloat {
            let remainingFrames = targetFrames - (accumulated.count / bytesPerFloat)
            let chunkCapacity = AVAudioFrameCount(max(remainingFrames, 1))
            let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: chunkCapacity)!

            var error: NSError?
            let status = converter.convert(to: dstBuf, error: &error) { _, statusPtr in
                if let buf = inputState.take() {
                    statusPtr.pointee = .haveData
                    return buf
                }
                statusPtr.pointee = .endOfStream
                return nil
            }

            let dstLen = Int(dstBuf.frameLength)
            if dstLen > 0 {
                let bytes = dstLen * bytesPerFloat
                let appended = Data(bytes: dstBuf.floatChannelData![0], count: bytes)
                accumulated.append(appended)
            }

            if status == .endOfStream || status == .error { break }
            if dstLen == 0 { break }
        }

        // Truncate or zero-pad to exact expected frame count for deterministic output.
        let expectedBytes = targetFrames * bytesPerFloat
        if accumulated.count > expectedBytes {
            accumulated = accumulated.prefix(expectedBytes)
        } else if accumulated.count < expectedBytes {
            accumulated.append(Data(count: expectedBytes - accumulated.count))
        }
        return AudioFrame(pcm: accumulated, sampleRate: targetSampleRate, channels: frame.channels, format: .float32)
    }

    private static func convertFloat32ToInt16(_ frame: AudioFrame) -> AudioFrame {
        guard frame.format == .float32 else { fatalError("expected .float32") }
        let n = frame.sampleCount
        var out = Data(count: n * 2)
        frame.pcm.withUnsafeBytes { srcRaw in
            let src = srcRaw.bindMemory(to: Float.self).baseAddress!
            out.withUnsafeMutableBytes { dstRaw in
                let dst = dstRaw.bindMemory(to: Int16.self).baseAddress!
                for i in 0..<n {
                    let clamped = max(-1.0, min(1.0, src[i]))
                    dst[i] = Int16(clamped * 32_767)
                }
            }
        }
        return AudioFrame(pcm: out, sampleRate: frame.sampleRate, channels: frame.channels, format: .int16)
    }

    private static func convertInt16ToFloat32(_ frame: AudioFrame) -> AudioFrame {
        guard frame.format == .int16 else { fatalError("expected .int16") }
        let n = frame.sampleCount
        var out = Data(count: n * 4)
        frame.pcm.withUnsafeBytes { srcRaw in
            let src = srcRaw.bindMemory(to: Int16.self).baseAddress!
            out.withUnsafeMutableBytes { dstRaw in
                let dst = dstRaw.bindMemory(to: Float.self).baseAddress!
                for i in 0..<n {
                    dst[i] = Float(src[i]) / 32_767.0
                }
            }
        }
        return AudioFrame(pcm: out, sampleRate: frame.sampleRate, channels: frame.channels, format: .float32)
    }
}
