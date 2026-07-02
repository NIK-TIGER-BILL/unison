import Foundation

/// Coalesces tiny wire-format audio frames into ~`targetDurationMs` sends.
///
/// The captures deliver HAL-IO-cycle-sized frames (~10 ms for Process Tap,
/// CMSampleBuffer-sized for the mic). Sending each one as its own WebSocket
/// message meant ~100 JSON+base64 messages per second per stream — pure
/// overhead (the providers' own guidance is 50–100 ms chunks) — and it
/// silently broke the reconnect ring buffer's sizing assumption
/// (`TranslationOrchestrator.audioBufferFrames` = 30 frames as "3 s at
/// ~100 ms frames": with 10 ms frames it held only ~0.3 s of replay).
/// Batching at the send boundary restores both. Pure value type — the
/// pipeline sender tasks own one instance each; no locking needed.
public struct WireFrameBatcher {
    private let targetDurationMs: Double
    private var pending: Data = Data()
    private var pendingRate: Int = 0
    private var pendingChannels: Int = 1
    private var pendingFormat: AudioSampleFormat = .int16

    public init(targetDurationMs: Double = 100) {
        self.targetDurationMs = targetDurationMs
    }

    private var pendingDurationMs: Double {
        guard pendingRate > 0, !pending.isEmpty else { return 0 }
        let bytesPerSample = pendingFormat == .int16 ? 2 : 4
        let samples = pending.count / (bytesPerSample * pendingChannels)
        return Double(samples) * 1000.0 / Double(pendingRate)
    }

    private var pendingFrame: AudioFrame? {
        guard !pending.isEmpty, pendingRate > 0 else { return nil }
        return AudioFrame(pcm: pending, sampleRate: pendingRate,
                          channels: pendingChannels, format: pendingFormat)
    }

    /// Add one wire frame. Returns a batch to send when the accumulated
    /// audio reaches the target duration (or when an incompatible frame
    /// forces the pending batch out early), `nil` while still accumulating.
    /// Empty frames are dropped — there is nothing to transmit.
    public mutating func add(_ frame: AudioFrame) -> AudioFrame? {
        guard !frame.pcm.isEmpty else { return nil }
        // Incompatible payload (rate/format/channel change mid-stream, e.g.
        // an engine switch): emit what's pending as-is — concatenating
        // mismatched PCM would corrupt it — and start over with this frame.
        if !pending.isEmpty,
           frame.sampleRate != pendingRate
            || frame.format != pendingFormat
            || frame.channels != pendingChannels {
            let out = pendingFrame
            begin(with: frame)
            return out
        }
        if pending.isEmpty { begin(with: frame) } else { pending.append(frame.pcm) }
        guard pendingDurationMs >= targetDurationMs else { return nil }
        let out = pendingFrame
        pending = Data()
        return out
    }

    /// Emit whatever is pending (stream end / teardown). Returns `nil` when
    /// nothing is buffered.
    public mutating func flush() -> AudioFrame? {
        let out = pendingFrame
        pending = Data()
        return out
    }

    private mutating func begin(with frame: AudioFrame) {
        pending = frame.pcm
        pendingRate = frame.sampleRate
        pendingChannels = frame.channels
        pendingFormat = frame.format
    }
}
