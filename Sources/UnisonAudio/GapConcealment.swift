import Foundation

/// NetEq-style packet-loss concealment for the translated-audio players —
/// the "right medicine" for the residual micropauses the jitter buffer
/// cannot cover (sustained model slowdowns where the cumulative shortfall
/// exceeds any held cushion; ~3.8 % of ticks in the field measurements,
/// previously left as audible hard-cut silence).
///
/// **What it does.** When the player is about to drain mid-speech, the
/// mixer schedules ONE short synthetic buffer: the last pitch period of the
/// real audio, tiled and faded to zero over ~200 ms. A hard mid-phoneme cut
/// becomes a natural-sounding release. If the gap was a real end-of-turn,
/// the phrase's last phoneme just decays marginally longer — inaudible; if
/// the model was merely late, the seam declick ramps the resumed audio back
/// in from the concealment's silent end.
///
/// **What it deliberately does NOT do (v1).** No comfort noise after the
/// fade, no time-scale modification of subsequent audio (WSOLA), at most
/// one concealment per dry spell — long outages still go silent, which is
/// the honest signal that the stream stalled.
///
/// Pure functions — deterministic, engine-free, covered by
/// `GapConcealmentTests`.
enum GapConcealment {
    /// Analysis/synthesis tail the mixer keeps from the last real buffer
    /// (~40 ms at 48 kHz): long enough for two periods of a 60 Hz voice.
    static let tailSamples = 1_920
    /// Synthetic buffer length: long enough to bridge the typical 100–300 ms
    /// arrival gap, short enough that a genuine end-of-turn just sounds like
    /// a slightly longer release.
    static let durationSec = 0.2
    /// Below this RMS the tail is silence — nothing worth continuing.
    static let silenceFloor: Float = 0.005
    /// Voiced-detection threshold on the normalized autocorrelation peak.
    static let voicingThreshold: Float = 0.5
    /// Pitch search range, in Hz, covering low male to high female voices.
    static let minPitchHz = 60.0, maxPitchHz = 400.0
    /// Diagnostic A/B gate: `UNISON_DISABLE_CONCEAL=1` turns concealment
    /// off so harness runs can measure the raw underrun floor.
    static let disabled =
        ProcessInfo.processInfo.environment["UNISON_DISABLE_CONCEAL"] == "1"

    /// Estimate the fundamental period (in samples) of the tail via
    /// normalized autocorrelation, aligned to the END of the tail (the most
    /// recent audio is what the concealment must continue). Returns `nil`
    /// for unvoiced/noise tails (peak below `voicingThreshold`) or silence.
    static func estimatePitchPeriod(tail: [Float], sampleRate: Int) -> Int? {
        let minLag = Int(Double(sampleRate) / maxPitchHz)          // 120 @48k
        let maxLag = Int(Double(sampleRate) / minPitchHz)          // 800 @48k
        guard tail.count > maxLag + minLag else { return nil }
        // Energy gate — silence has no pitch.
        var energy: Float = 0
        for s in tail { energy += s * s }
        guard (energy / Float(tail.count)).squareRoot() >= silenceFloor else { return nil }

        // Correlation window: the last `window` samples vs. the same window
        // shifted back by each candidate lag.
        let window = min(960, tail.count - maxLag)
        let end = tail.count
        var bestLag = 0
        var bestCorr: Float = 0
        for lag in minLag...maxLag {
            var dot: Float = 0, e1: Float = 0, e2: Float = 0
            let aStart = end - window
            let bStart = end - window - lag
            for i in 0..<window {
                let a = tail[aStart + i]
                let b = tail[bStart + i]
                dot += a * b
                e1 += a * a
                e2 += b * b
            }
            let denom = (e1 * e2).squareRoot()
            guard denom > 0 else { continue }
            let corr = dot / denom
            // Strictly greater — on harmonic ties (a pure sine correlates
            // perfectly at 2P, 3P, …) keep the SHORTEST lag, the true period.
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }
        return bestCorr >= voicingThreshold ? bestLag : nil
    }

    /// Build the concealment signal: the tail's last pitch period (or a
    /// 10 ms block for unvoiced tails) tiled for `durationSec` and faded
    /// linearly to zero. `concealment[0]` continues the waveform exactly one
    /// period after the tail's last sample, so playback flows through the
    /// splice; the linear envelope ends at (near-)zero, so whatever follows
    /// — resumed audio via the seam declick, or silence — starts clean.
    /// Returns `nil` when the tail is too short or silent.
    static func makeConcealment(tail: [Float], sampleRate: Int,
                                durationSec: Double = GapConcealment.durationSec) -> [Float]? {
        guard tail.count >= 480 else { return nil }
        var energy: Float = 0
        for s in tail { energy += s * s }
        guard (energy / Float(tail.count)).squareRoot() >= silenceFloor else { return nil }

        let period: Int
        if let pitch = estimatePitchPeriod(tail: tail, sampleRate: sampleRate) {
            period = pitch
        } else {
            // Unvoiced (fricative/noise): repeat a 10 ms block — periodicity
            // doesn't matter for noise, the fade does.
            period = min(sampleRate / 100, tail.count)
        }
        guard tail.count >= period, period > 0 else { return nil }

        let n = Int(durationSec * Double(sampleRate))
        let base = tail.count - period
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let env = 1.0 - Float(i) / Float(n)
            out[i] = tail[base + (i % period)] * env
        }
        return out
    }
}
