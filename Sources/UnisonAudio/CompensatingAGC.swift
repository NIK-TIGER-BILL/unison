import Foundation

/// Compensating Automatic Gain Control for the translation player's
/// output PCM, applied to counteract `gpt-realtime-translate`'s
/// progressive amplitude fade on long continuous sessions.
///
/// **Why this exists.** Direct measurement with the harness showed
/// that `gpt-realtime-translate` attenuates its own output amplitude
/// over the course of a continuous session by ~55-66 % over 20-25 s,
/// even when our input is amplitude-stable (we verified
/// `sent.wav` flat → `wire.wav` fading). The fade resets when the
/// session pauses (silence > ~3 s, model state apparently clears).
/// No public report of this behaviour exists; the model is three
/// weeks old. We compensate on the client side instead of waiting
/// for an OpenAI fix.
///
/// **Algorithm.** Track a long-time-constant EMA of the model's
/// recent output RMS (only during voiced frames, ignoring silence).
/// Compute a target gain that pulls the long-term RMS back to a
/// reference level (≈ what a fresh session emits initially). Slew-
/// rate-limit the gain so transitions are smooth and not "pumping",
/// clamp to `[minGain, maxGain]` to keep behaviour safe, and zero
/// out the multiplier when we detect a silence stretch — that's the
/// "reset on pause" matching the model's own behaviour.
///
/// **Pure function exposed for tests.** `processed(_:state:config:)`
/// returns the new state + adjusted samples without touching any
/// shared global. The class `CompensatingAGC` is just a stateful
/// wrapper around it for the real-time path.
public struct AGCConfig: Sendable {
    /// Minimum loudness floor for the adaptive target. The AGC restores
    /// faded audio to the session's own peak RMS (see
    /// `AGCState.sessionPeakRMS`); `targetRMS` is the floor it won't
    /// target below, so a genuinely-quiet session still reaches a sane
    /// level. ≈ 0.05 matches OpenAI's fresh output; louder engines
    /// (Gemini ≈ 0.12) self-target their own peak above it.
    public let targetRMS: Double
    /// Maximum gain multiplier. 4× ≈ +12 dB — covers our worst-case
    /// observed fade (Q4/Q1 ≈ 30 % → need ~3.3× to restore).
    public let maxGain: Float
    /// Minimum gain multiplier. 1.0 means we never attenuate
    /// — we only ever boost faded model output.
    public let minGain: Float
    /// Time constant (seconds) of the long-term RMS EMA. The per-frame
    /// coefficient is derived as `α = 1 − exp(−frameDuration/τ)`, so the
    /// tracker converges at the same wall-clock speed no matter how the
    /// engine chunks its output. (The old fixed per-frame α assumed 100 ms
    /// frames; the model actually ships 250–400 ms chunks, which silently
    /// slowed the tracker 2.5–4×.)
    public let rmsTauSec: Double
    /// Max gain change per SECOND, scaled by each frame's duration. 0.2/s
    /// gives smooth, non-pumping transitions and full fade compensation
    /// (×2.5–3.3) within ~10 s — independent of chunk size.
    public let gainSlewPerSec: Float
    /// Below this RMS, a frame is considered silence — don't update
    /// the RMS tracker (would bias it down) and don't apply boost.
    public let silenceFloor: Double
    /// Silence-stretch duration that triggers a state reset. The model
    /// itself appears to reset its internal state after roughly this
    /// much input silence, so we match.
    public let resetSilenceSec: Double

    public static let `default` = AGCConfig(
        targetRMS: 0.05,
        maxGain: 4.0,
        minGain: 1.0,
        rmsTauSec: 5.0,
        gainSlewPerSec: 0.2,
        silenceFloor: 0.005,
        resetSilenceSec: 3.0
    )

    public init(targetRMS: Double, maxGain: Float, minGain: Float,
                rmsTauSec: Double, gainSlewPerSec: Float,
                silenceFloor: Double, resetSilenceSec: Double) {
        self.targetRMS = targetRMS
        self.maxGain = maxGain
        self.minGain = minGain
        self.rmsTauSec = rmsTauSec
        self.gainSlewPerSec = gainSlewPerSec
        self.silenceFloor = silenceFloor
        self.resetSilenceSec = resetSilenceSec
    }
}

public struct AGCState: Equatable, Sendable {
    /// Long-term EMA of recent frame RMS. Reset to 0 on init/silence.
    public var longTermRMS: Double
    /// Currently-applied gain. Slewed toward target each frame.
    public var currentGain: Float
    /// Seconds of consecutive silence observed. Once this exceeds
    /// `config.resetSilenceSec`, the controller resets to fresh state.
    public var silenceAccumSec: Double
    /// Peak long-term RMS seen this session — the "fresh" level before
    /// the model's fade. The adaptive target: we restore faded audio to
    /// THIS level (floored at `config.targetRMS`), so the compensation
    /// auto-calibrates to each engine's output loudness (OpenAI ≈ 0.05,
    /// Gemini ≈ 0.12) and to the speaker/mic — rather than pinning every
    /// engine at a single hard-coded level that left louder engines
    /// audibly fading down to it. Reset to 0 on silence.
    public var sessionPeakRMS: Double

    public static let initial = AGCState(longTermRMS: 0, currentGain: 1.0,
                                         silenceAccumSec: 0, sessionPeakRMS: 0)
}

public enum CompensatingAGC {
    /// Pure-function one-frame step.
    /// - parameter samples: float32 mono PCM of one frame. NOT mutated.
    /// - parameter frameDurationSec: wall-clock duration this frame
    ///   represents — used to advance the silence accumulator. For
    ///   our pipeline this is `samples.count / 48_000`.
    /// - parameter state: previous state.
    /// - parameter config: thresholds + smoothing.
    /// - returns: (newState, scaledSamples).
    public static func processed(samples: [Float],
                                 frameDurationSec: Double,
                                 state: AGCState,
                                 config: AGCConfig) -> (AGCState, [Float]) {
        // Compute frame RMS.
        let n = samples.count
        if n == 0 { return (state, samples) }
        var sumSq: Double = 0
        for s in samples { sumSq += Double(s) * Double(s) }
        let frameRMS = (sumSq / Double(n)).squareRoot()

        var newState = state

        // Silence handling: if this frame is below the noise floor,
        // accumulate silence time; if accumulated silence exceeds
        // reset threshold, snap state back to initial. This mirrors
        // the model's own state-reset behaviour on pause.
        //
        // CRITICAL: we still APPLY the current gain to silent frames
        // (just don't update the EMA / gain controller). Returning
        // unmodified samples here would create a sudden gain-drop on
        // word tails that briefly dip below the noise floor — the
        // user perceived this as "the audio chunk getting cut off
        // before it finished". Continuous gain envelope > suppressing
        // ambient noise.
        if frameRMS < config.silenceFloor {
            newState.silenceAccumSec += frameDurationSec
            if newState.silenceAccumSec >= config.resetSilenceSec {
                newState = .initial
            }
            let g = newState.currentGain
            var out = samples
            out.withUnsafeMutableBufferPointer { buf in
                for i in 0..<n {
                    buf[i] *= g
                }
            }
            return (newState, out)
        } else {
            newState.silenceAccumSec = 0
        }

        // Update long-term RMS using only voiced frames. The EMA
        // coefficient is derived from the frame's actual duration so the
        // tracker's wall-clock time constant (τ = rmsTauSec) holds for any
        // chunk size the engine ships (100 ms and 400 ms behave the same).
        if newState.longTermRMS == 0 {
            // First voiced frame: bootstrap directly so we don't have
            // to wait for EMA to converge from 0.
            newState.longTermRMS = frameRMS
        } else {
            let alpha = 1.0 - exp(-frameDurationSec / config.rmsTauSec)
            newState.longTermRMS = newState.longTermRMS * (1.0 - alpha)
                                 + frameRMS * alpha
        }

        // Track the session's peak (fresh) level — the loudest the
        // long-term RMS has reached before the fade pulls it down.
        newState.sessionPeakRMS = max(state.sessionPeakRMS, newState.longTermRMS)

        // Desired gain restores the faded long-term RMS back to the
        // session's fresh level (its peak), floored at `targetRMS` so a
        // genuinely-quiet session still reaches a sane minimum loudness.
        // Targeting the peak (not a fixed constant) is what fixes the
        // "gets quieter over a call" symptom on louder engines like
        // Gemini, whose fresh ≈ 0.12 sat well above the old 0.05 target.
        let target = max(newState.sessionPeakRMS, config.targetRMS)
        let desiredGain: Float
        if newState.longTermRMS > 0.0001 {
            desiredGain = Float(target / newState.longTermRMS)
        } else {
            desiredGain = 1.0
        }
        let clamped = max(config.minGain, min(config.maxGain, desiredGain))

        // Slew toward clamped target, scaled by the frame's duration so the
        // gain moves at `gainSlewPerSec` regardless of chunk size.
        let maxStep = config.gainSlewPerSec * Float(frameDurationSec)
        let delta = clamped - state.currentGain
        let limited = max(-maxStep, min(maxStep, delta))
        newState.currentGain = state.currentGain + limited

        // Apply gain to samples.
        let g = newState.currentGain
        var out = samples
        out.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                buf[i] *= g
            }
        }
        return (newState, out)
    }
}

/// Stateful real-time wrapper used by the playback path. Lock-free
/// because each player has its own instance and processing happens
/// on a single producer task (the `for await frame in frames`
/// consumer in `AVAudioOutputMixer.playTranslated` /
/// `BlackHole2chPlayer.play`).
public final class CompensatingAGCRunner {
    private let config: AGCConfig
    private var state: AGCState

    public init(config: AGCConfig = .default) {
        self.config = config
        self.state = .initial
    }

    /// Reset to initial state. Call from the engine-stop / play-start
    /// boundaries so a new session begins with gain = 1.0.
    public func reset() {
        state = .initial
    }

    /// Apply one frame. Returns the gain-adjusted PCM bytes (float32
    /// LE) along with the gain applied for diagnostic logging.
    public func apply(pcmF32: Data, frameDurationSec: Double) -> (Data, Float) {
        let count = pcmF32.count / MemoryLayout<Float>.size
        guard count > 0 else { return (pcmF32, state.currentGain) }
        var samples = [Float](repeating: 0, count: count)
        samples.withUnsafeMutableBufferPointer { dst in
            pcmF32.withUnsafeBytes { src in
                _ = memcpy(dst.baseAddress!, src.baseAddress!, pcmF32.count)
            }
        }
        let (newState, processed) = CompensatingAGC.processed(
            samples: samples,
            frameDurationSec: frameDurationSec,
            state: state,
            config: config
        )
        state = newState
        var outData = Data(count: pcmF32.count)
        processed.withUnsafeBufferPointer { src in
            outData.withUnsafeMutableBytes { dst in
                _ = memcpy(dst.baseAddress!, src.baseAddress!, pcmF32.count)
            }
        }
        return (outData, state.currentGain)
    }

    /// Snapshot current gain — used by diagnostic logging.
    public var currentGain: Float { state.currentGain }
    /// Snapshot current long-term RMS — used by diagnostic logging.
    public var longTermRMS: Double { state.longTermRMS }
}
