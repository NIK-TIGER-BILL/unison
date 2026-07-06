import Foundation
import AVFoundation
import UnisonDomain

/// Stateful, continuity-preserving resampler for the live audio pipelines.
///
/// **Why not the one-shot `Resampler`.** The static path `.reset()`s its
/// cached `AVAudioConverter` before every chunk and drains it with
/// `.endOfStream`, then truncates / zero-pads the output to the expected
/// length. That makes each chunk deterministic in isolation (what its tests
/// pin down), but every chunk boundary in a LIVE stream gets a filter
/// restart transient plus injected zeros — an artificial seam. The capture
/// side delivers HAL-IO-cycle frames (~10 ms), so the engine used to hear
/// ~100 seams per second of what should be one continuous signal; the
/// playback side got one seam per model chunk, partially papered over by
/// the seam declick.
///
/// **This class keeps the converter's filter state across chunks**: one
/// `AVAudioConverter` per (srcRate → dstRate) direction per INSTANCE, never
/// reset mid-stream, fed with `.noDataNow` (not `.endOfStream`) when a
/// chunk's samples run out so the filter tail carries into the next chunk.
/// Output length per chunk is whatever the converter yields (steady-state
/// exact for our integer ratios, minus a small constant prime latency at
/// stream start) — downstream consumers size everything off the actual
/// sample counts, so no padding is needed.
///
/// **Ownership.** One instance per PIPELINE (the orchestrator calls
/// `AudioFormatTransformer.makeStreamTransformer()` when wiring each one):
/// the me-pipeline and peer-pipeline convert the same rate pairs
/// concurrently, and sharing filter state between two different signals
/// would corrupt both. Within an instance, a single lock serializes the
/// (rare) case of both directions converting at once — the send loop and
/// the receive pump are separate tasks.
public final class StreamingResampler: AudioFormatTransformer, @unchecked Sendable {
    /// One live conversion lane: the converter plus its (cached) formats.
    private struct Lane {
        let converter: AVAudioConverter
        let dstFormat: AVAudioFormat
    }

    private struct Key: Hashable {
        let srcRate: Int
        let dstRate: Int
    }

    private let lock = NSLock()
    private var lanes: [Key: Lane] = [:]
    /// Same category as `ResamplerAdapter` — the "conversion path came up
    /// with the right formats" diagnostic moved here when the live
    /// pipelines switched to the streaming path (PR #16), silently killing
    /// the adapter's first-call lines (and the VM integration assertion
    /// that greps for them). Latched per instance: one line per pipeline
    /// per direction, hot path stays log-free.
    private static let log = UnisonLog(category: "Resampler")
    private var loggedToWire = false
    private var loggedFromWire = false

    public init() {}

    public func makeStreamTransformer() -> any AudioFormatTransformer {
        // Already a per-pipeline streaming instance; hand out a fresh one so
        // an accidental second wiring never shares filter state.
        StreamingResampler()
    }

    public func toWire(_ frame: AudioFrame, sampleRate: Int) -> AudioFrame {
        if frame.sampleRate == sampleRate, frame.format == .int16, frame.channels == 1 { return frame }
        let f32 = frame.format == .float32 ? frame : Resampler.convertInt16ToFloat32(frame)
        let resampled = resample(Resampler.mixdownToMono(f32), to: sampleRate)
        let out = Resampler.convertFloat32ToInt16(resampled)
        logFirstCall(direction: "toWire", flag: &loggedToWire, input: frame, output: out)
        return out
    }

    public func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        let f32 = frame.format == .float32 ? frame : Resampler.convertInt16ToFloat32(frame)
        let out = resample(Resampler.mixdownToMono(f32), to: targetSampleRate)
        logFirstCall(direction: "fromWire", flag: &loggedFromWire, input: frame, output: out)
        return out
    }

    /// One diagnostic line per direction per pipeline instance, proving the
    /// conversion path is live and the formats are what we expect (e.g.
    /// `fromWire — first call: in=24000Hz int16 → out=48000Hz float32`).
    /// The VM integration test asserts on it.
    private func logFirstCall(direction: String, flag: inout Bool,
                              input: AudioFrame, output: AudioFrame) {
        lock.lock()
        let shouldLog = !flag
        if shouldLog { flag = true }
        lock.unlock()
        guard shouldLog else { return }
        Self.log.info("\(direction) — first call: in=\(input.sampleRate)Hz \(String(describing: input.format))"
            + " → out=\(output.sampleRate)Hz \(String(describing: output.format))")
    }

    // MARK: - Streaming conversion core

    private func resample(_ frame: AudioFrame, to targetRate: Int) -> AudioFrame {
        guard frame.format == .float32 else {
            fatalError("StreamingResampler.resample expects .float32 input")
        }
        precondition(frame.channels == 1,
                     "StreamingResampler only supports mono frames; got channels=\(frame.channels). Mix down upstream.")
        if frame.sampleRate == targetRate { return frame }
        // Empty frames slip through on cold start of the mic capture —
        // pass through re-tagged (same contract as the one-shot path).
        if frame.sampleCount == 0 {
            return AudioFrame(pcm: Data(), sampleRate: targetRate,
                              channels: 1, format: .float32)
        }

        lock.lock(); defer { lock.unlock() }
        guard let lane = laneLocked(srcRate: frame.sampleRate, dstRate: targetRate) else {
            // AVAudioConverter init is failable but never fails for our PCM
            // pairs; degrade to the one-shot path rather than dropping audio.
            return Resampler.fromWire(frame, targetSampleRate: targetRate)
        }

        let srcFrames = AVAudioFrameCount(frame.sampleCount)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: lane.converter.inputFormat,
                                            frameCapacity: srcFrames) else {
            return Resampler.fromWire(frame, targetSampleRate: targetRate)
        }
        srcBuf.frameLength = srcFrames
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(srcBuf.floatChannelData![0], p, frame.pcm.count)
        }

        let bytesPerFloat = MemoryLayout<Float>.size
        let expectedFrames = Int((Double(frame.sampleCount) * Double(targetRate)) / Double(frame.sampleRate))
        var accumulated = Data()
        accumulated.reserveCapacity((expectedFrames + 64) * bytesPerFloat)

        // Feed this chunk's samples exactly once; when the converter asks
        // for more, answer `.noDataNow` — NOT `.endOfStream` — so its filter
        // state stays primed for the next chunk. Drain everything it can
        // produce from the available input.
        let inputState = ConverterInputState(buffer: srcBuf)
        while true {
            let capacity = AVAudioFrameCount(max(256, expectedFrames + 64))
            guard let dstBuf = AVAudioPCMBuffer(pcmFormat: lane.dstFormat,
                                                frameCapacity: capacity) else { break }
            var error: NSError?
            let status = lane.converter.convert(to: dstBuf, error: &error) { _, statusPtr in
                if let buf = inputState.take() {
                    statusPtr.pointee = .haveData
                    return buf
                }
                statusPtr.pointee = .noDataNow
                return nil
            }
            let produced = Int(dstBuf.frameLength)
            if produced > 0 {
                accumulated.append(Data(bytes: dstBuf.floatChannelData![0],
                                        count: produced * bytesPerFloat))
            }
            // `.haveData` with a full buffer means more output may be
            // pending; anything else (input ran dry / error) ends the chunk.
            if status != .haveData || produced == 0 { break }
        }

        return AudioFrame(pcm: accumulated, sampleRate: targetRate,
                          channels: 1, format: .float32)
    }

    /// Get-or-create the conversion lane for a direction. Caller holds `lock`.
    private func laneLocked(srcRate: Int, dstRate: Int) -> Lane? {
        let key = Key(srcRate: srcRate, dstRate: dstRate)
        if let lane = lanes[key] { return lane }
        guard let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(srcRate),
                                         channels: 1, interleaved: false),
              let dstFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(dstRate),
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFmt, to: dstFmt) else { return nil }
        let lane = Lane(converter: converter, dstFormat: dstFmt)
        lanes[key] = lane
        return lane
    }
}
