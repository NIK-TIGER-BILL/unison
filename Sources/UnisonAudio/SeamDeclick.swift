import Foundation
import AVFoundation

/// Chunk-seam declick shared by BOTH translated-audio players — the local
/// speakers (`AVAudioOutputMixer`) and the virtual mic the peer hears
/// (`BlackHole2chPlayer`). Extracted so the peer path gets the exact same
/// seam treatment the speakers path shipped with (it previously had none:
/// the peer heard the boundary clicks the local listener didn't).
///
/// Semantics (see `DeclickTests` for the deterministic proof):
///  • Continuous playback — ramp the first ~2 ms of a new buffer from the
///    previous buffer's last sample, smoothing resampler/AGC boundary steps.
///  • Resume after the player drained — ramp from 0, because the player was
///    emitting digital silence and any non-zero first sample would click.
enum SeamDeclick {
    /// Ramp length in samples (~2 ms at 48 kHz): long enough to remove a
    /// boundary click, short enough to be inaudible as a smear.
    static let rampSamples = 96

    /// Diagnostic A/B gate: `UNISON_DISABLE_DECLICK=1` skips the seam ramp so
    /// the full-chain click-verification harness can measure the click floor
    /// WITH vs WITHOUT it. Launch-constant (same-process env is immutable).
    static let disabled =
        ProcessInfo.processInfo.environment["UNISON_DISABLE_DECLICK"] == "1"

    /// Ramp the first `rampSamples` of `buf` from `start` into the actual
    /// signal (linear blend `out[i] = start·(1−g) + signal[i]·g`, `g = i/n`).
    /// `out[0] == start` so playback continues without a step, and by sample
    /// `n` we're back on the real waveform. Plain buffer math — runs on the
    /// schedule path, never the render thread.
    static func ramp(_ buf: AVAudioPCMBuffer, from start: Float) {
        guard let ch = buf.floatChannelData else { return }
        let p = ch[0]
        let n = min(Int(buf.frameLength), rampSamples)
        guard n > 1 else { return }
        for i in 0..<n {
            let g = Float(i) / Float(n)
            p[i] = start * (1 - g) + p[i] * g
        }
    }

    /// Pure: model the queue's end in host-clock seconds to decide whether
    /// the player drained to silence before this buffer. Returns
    /// `(resumingFromSilence, updatedQueueEndsAt)`. `now >= queueEndsAt` ⟺
    /// the queue emptied and the player is on digital silence → the caller
    /// ramps the seam from 0. Otherwise a chunk landed while audio was still
    /// queued (the cushion absorbed the jitter) → continuous seam, ramp from
    /// the last sample. The new end is `max(now, queueEndsAt) +
    /// bufferDurationSec`: a buffer arriving after a drain restarts the clock
    /// at `now`; one that appends extends the existing queue. Wall-clock
    /// based, so it's immune to the `.dataPlayedBack` completion lag.
    static func resumeDecision(now: Double, queueEndsAt: Double,
                               bufferDurationSec: Double) -> (resumingFromSilence: Bool, queueEndsAt: Double) {
        let resuming = now >= queueEndsAt
        let start = Swift.max(now, queueEndsAt)
        return (resuming, start + bufferDurationSec)
    }
}
