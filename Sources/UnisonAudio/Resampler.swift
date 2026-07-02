import Foundation
import AVFoundation
import UnisonDomain

/// Holds one-shot input state for an AVAudioConverter input callback.
/// Mutating the closure-captured state directly is rejected under strict
/// concurrency; wrapping it in a class with a locked accessor keeps the
/// closure non-mutating while preserving the "feed input once, then EOS"
/// pattern that AVAudioConverter requires when draining its internal tail.
/// `internal` (not `private`): `StreamingResampler` reuses it for its
/// "feed input once, then `.noDataNow`" streaming variant.
final class ConverterInputState: @unchecked Sendable {
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

/// Module-private cache of `AVAudioConverter` instances keyed by their
/// rate-pair / channel-count signature. Creating a converter allocates
/// filter coefficients; doing it once per ~100ms audio chunk shows up as
/// a measurable load on the render thread and was a strong candidate for
/// the "translation playback gets quieter over time" report. We cache
/// one converter per signature, then `.reset()` its internal filter
/// state at the start of each conversion to preserve the previous
/// "each chunk is independent" semantics so existing tests stay
/// deterministic.
///
/// AVAudioConverter is documented as not thread-safe, and our pipelines
/// can call the same rate-pair concurrently from both the local-mic and
/// process-tap (peer) sides. We hold the cache lock for the entire
/// conversion body to serialise both lookup and use against that case.
private final class CachedConverter: @unchecked Sendable {
    private struct Key: Hashable {
        let srcRate: Int
        let dstRate: Int
        let channels: Int
    }

    // Swift 6 strict concurrency flags shared mutable statics; the
    // `nonisolated(unsafe)` marker tells the compiler we provide external
    // synchronisation — in this case the NSLock immediately below.
    nonisolated(unsafe) private static var cache: [Key: AVAudioConverter] = [:]
    private static let lock = NSLock()

    /// Run `body` with a fresh-state converter for the requested signature.
    /// Returns `nil` if AVAudioConverter could not be constructed (invalid
    /// formats — never seen in practice for the pairs we use, but the
    /// initializer is failable).
    static func use<R>(srcRate: Int,
                       dstRate: Int,
                       channels: Int,
                       _ body: (AVAudioConverter) -> R) -> R? {
        let key = Key(srcRate: srcRate, dstRate: dstRate, channels: channels)
        lock.lock(); defer { lock.unlock() }
        let converter: AVAudioConverter
        if let cached = cache[key] {
            cached.reset()
            converter = cached
        } else {
            let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Double(srcRate),
                                       channels: AVAudioChannelCount(channels),
                                       interleaved: false)!
            let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: Double(dstRate),
                                       channels: AVAudioChannelCount(channels),
                                       interleaved: false)!
            guard let fresh = AVAudioConverter(from: srcFmt, to: dstFmt) else { return nil }
            cache[key] = fresh
            converter = fresh
        }
        return body(converter)
    }
}

public enum Resampler {
    public static func toWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        if frame.sampleRate == targetSampleRate, frame.format == .int16, frame.channels == 1 { return frame }
        let f32 = frame.format == .float32 ? frame : convertInt16ToFloat32(frame)
        let f32t = resampleFloat32(mixdownToMono(f32), targetSampleRate: targetSampleRate)
        return convertFloat32ToInt16(f32t)
    }

    public static func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        let f32 = frame.format == .float32 ? frame : convertInt16ToFloat32(frame)
        return resampleFloat32(mixdownToMono(f32), targetSampleRate: targetSampleRate)
    }

    // MARK: - Helpers

    /// Average interleaved channels into one mono channel. Multi-channel
    /// frames that reach the resampler are interleaved by construction:
    /// CoreAudio ABL buffers with `mNumberChannels > 1` and
    /// `CMSampleBuffer` audio carry interleaved layouts, and the
    /// captures reduce planar (non-interleaved) buffers to their first
    /// plane before frames enter the pipeline. No-op for mono input.
    /// `internal`: shared with `StreamingResampler`.
    static func mixdownToMono(_ frame: AudioFrame) -> AudioFrame {
        guard frame.channels > 1 else { return frame }
        guard frame.format == .float32, !frame.pcm.isEmpty else {
            // Empty multi-channel frame — re-tag only.
            return AudioFrame(pcm: frame.pcm, sampleRate: frame.sampleRate,
                              channels: 1, format: frame.format)
        }
        let ch = frame.channels
        let frameCount = frame.sampleCount
        var out = Data(count: frameCount * MemoryLayout<Float>.size)
        frame.pcm.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.bindMemory(to: Float.self).baseAddress else { return }
            out.withUnsafeMutableBytes { dstRaw in
                guard let dst = dstRaw.bindMemory(to: Float.self).baseAddress else { return }
                for i in 0..<frameCount {
                    var acc: Float = 0
                    for c in 0..<ch { acc += src[i * ch + c] }
                    dst[i] = acc / Float(ch)
                }
            }
        }
        return AudioFrame(pcm: out, sampleRate: frame.sampleRate, channels: 1, format: .float32)
    }

    private static func resampleFloat32(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        guard frame.format == .float32 else {
            fatalError("resampleFloat32 expects .float32 input")
        }
        // Mono load-bearing assumption: we use planar (`interleaved: false`)
        // AVAudioFormats and a single-channel `memcpy(dstBuf.floatChannelData![0], ...)`.
        // A multi-channel frame would have its later channels silently dropped
        // (or worse, corrupt the planar buffer's tail). The whole pipeline —
        // Process Tap capture, mic capture, OpenAI wire — is mono today; this
        // precondition makes that invariant load-bearing rather than implicit.
        precondition(frame.channels == 1,
                     "Resampler.resampleFloat32 only supports mono frames; got channels=\(frame.channels). Mix down upstream.")
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

        var accumulated = CachedConverter.use(srcRate: frame.sampleRate,
                                              dstRate: targetSampleRate,
                                              channels: frame.channels) { converter -> Data in
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
            return accumulated
        } ?? Data()

        // Truncate or zero-pad to exact expected frame count for deterministic output.
        let expectedBytes = targetFrames * bytesPerFloat
        if accumulated.count > expectedBytes {
            accumulated = accumulated.prefix(expectedBytes)
        } else if accumulated.count < expectedBytes {
            accumulated.append(Data(count: expectedBytes - accumulated.count))
        }
        return AudioFrame(pcm: accumulated, sampleRate: targetSampleRate, channels: frame.channels, format: .float32)
    }

    /// `internal`: shared with `StreamingResampler`.
    static func convertFloat32ToInt16(_ frame: AudioFrame) -> AudioFrame {
        guard frame.format == .float32 else { fatalError("expected .float32") }
        // Total sample values across ALL channels — `sampleCount` is
        // per-channel frames, which would convert only 1/N of an
        // interleaved multi-channel buffer.
        let n = frame.pcm.count / MemoryLayout<Float>.size
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

    /// `internal`: shared with `StreamingResampler`.
    static func convertInt16ToFloat32(_ frame: AudioFrame) -> AudioFrame {
        guard frame.format == .int16 else { fatalError("expected .int16") }
        // Total sample values across ALL channels (see note in
        // `convertFloat32ToInt16`).
        let n = frame.pcm.count / MemoryLayout<Int16>.size
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
