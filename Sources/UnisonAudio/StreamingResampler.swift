import AVFoundation

/// Stateful mono float32 resampler wrapping a persistent `AVAudioConverter`.
///
/// Unlike `Resampler` (which `.reset()`s its converter every chunk for
/// independent-chunk semantics), this keeps the converter's polyphase filter
/// state ACROSS calls, so the output is **time-invariant / phase-continuous
/// (LTI)** and low-imaging. AEC needs both: the echo in the resampled near
/// signal must be a *fixed, clean* linear function of the resampled far
/// reference for Speex's adaptive filter to converge. A per-chunk-reset
/// resampler injects a fresh transient at every boundary (→ ~0 dB cancellation
/// when near and far are resampled by different ratios), and a linear resampler
/// leaks strong spectral images the filter can't match (→ a few dB). A
/// persistent `AVAudioConverter` avoids both.
///
/// Streaming contract: each `resample` feeds one input buffer and drains what
/// the converter can emit WITHOUT flushing its tail (`.noDataNow`, not
/// `.endOfStream`), so a constant per-stream latency is held back and the rest
/// flows out on subsequent calls — fine for AEC (a fixed delay is absorbed by
/// Speex's filter tail). Single-threaded; used on the mic thread.
final class StreamingResampler {
    let srcRate: Int
    let dstRate: Int
    private let converter: AVAudioConverter
    private let srcFmt: AVAudioFormat
    private let dstFmt: AVAudioFormat

    init?(srcRate: Int, dstRate: Int) {
        guard let s = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: Double(srcRate), channels: 1, interleaved: false),
              let d = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                    sampleRate: Double(dstRate), channels: 1, interleaved: false),
              let c = AVAudioConverter(from: s, to: d) else { return nil }
        self.srcRate = srcRate
        self.dstRate = dstRate
        self.srcFmt = s
        self.dstFmt = d
        self.converter = c
    }

    /// Drop the filter history (call on session reset, not per chunk).
    func reset() { converter.reset() }

    /// Feed `input` (mono float32 at `srcRate`) and return whatever the
    /// converter produces at `dstRate`, preserving state across calls.
    func resample(_ input: [Float]) -> [Float] {
        guard !input.isEmpty else { return [] }
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: srcFmt,
                                           frameCapacity: AVAudioFrameCount(input.count)) else { return [] }
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            memcpy(inBuf.floatChannelData![0], src.baseAddress!, input.count * MemoryLayout<Float>.size)
        }

        let cap = AVAudioFrameCount(Double(input.count) * Double(dstRate) / Double(srcRate) + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: dstFmt, frameCapacity: cap) else { return [] }

        var supplied = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, statusPtr in
            if supplied {
                statusPtr.pointee = .noDataNow   // keep the stream open — preserve state
                return nil
            }
            supplied = true
            statusPtr.pointee = .haveData
            return inBuf
        }
        guard status != .error, outBuf.frameLength > 0, let ch = outBuf.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: ch[0], count: Int(outBuf.frameLength)))
    }
}
