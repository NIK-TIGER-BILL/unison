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
    /// Target RMS to maintain. Calibrated against observed model
    /// output at the start of a session before fade kicks in
    /// (≈ 0.05 in our test recordings).
    public let targetRMS: Double
    /// Maximum gain multiplier. 4× ≈ +12 dB — covers our worst-case
    /// observed fade (Q4/Q1 ≈ 30 % → need ~3.3× to restore).
    public let maxGain: Float
    /// Minimum gain multiplier. 1.0 means we never attenuate
    /// — we only ever boost faded model output.
    public let minGain: Float
    /// EMA coefficient for the long-term RMS tracker. With ~10 frames
    /// per second (100 ms each) and target τ ≈ 5 s:
    /// α = 1 - exp(-0.1/5) ≈ 0.02.
    public let rmsAlpha: Double
    /// Max change in gain per frame. At 10 frames/sec with step 0.02,
    /// gain can move 0.2 per second — smooth transitions, no pumping.
    public let gainSlewPerFrame: Float
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
        rmsAlpha: 0.02,
        gainSlewPerFrame: 0.02,
        silenceFloor: 0.005,
        resetSilenceSec: 3.0
    )

    public init(targetRMS: Double, maxGain: Float, minGain: Float,
                rmsAlpha: Double, gainSlewPerFrame: Float,
                silenceFloor: Double, resetSilenceSec: Double) {
        self.targetRMS = targetRMS
        self.maxGain = maxGain
        self.minGain = minGain
        self.rmsAlpha = rmsAlpha
        self.gainSlewPerFrame = gainSlewPerFrame
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

    public static let initial = AGCState(longTermRMS: 0, currentGain: 1.0, silenceAccumSec: 0)
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
        if frameRMS < config.silenceFloor {
            newState.silenceAccumSec += frameDurationSec
            if newState.silenceAccumSec >= config.resetSilenceSec {
                newState = .initial
            }
            // Don't change gain during silence — keep current gain so
            // when speech resumes within reset window, gain is still
            // appropriate. Pass samples through unchanged.
            return (newState, samples)
        } else {
            newState.silenceAccumSec = 0
        }

        // Update long-term RMS using only voiced frames.
        if newState.longTermRMS == 0 {
            // First voiced frame: bootstrap directly so we don't have
            // to wait for EMA to converge from 0.
            newState.longTermRMS = frameRMS
        } else {
            newState.longTermRMS = newState.longTermRMS * (1.0 - config.rmsAlpha)
                                 + frameRMS * config.rmsAlpha
        }

        // Desired gain to bring long-term RMS to target.
        let desiredGain: Float
        if newState.longTermRMS > 0.0001 {
            desiredGain = Float(config.targetRMS / newState.longTermRMS)
        } else {
            desiredGain = 1.0
        }
        let clamped = max(config.minGain, min(config.maxGain, desiredGain))

        // Slew toward clamped target.
        let delta = clamped - state.currentGain
        let limited = max(-config.gainSlewPerFrame, min(config.gainSlewPerFrame, delta))
        newState.currentGain = state.currentGain + limited

        // Apply gain to samples.
        let g = newState.currentGain
        var out = samples
        out.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                buf[i] = buf[i] * g
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
                memcpy(dst.baseAddress!, src.baseAddress!, pcmF32.count)
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
                memcpy(dst.baseAddress!, src.baseAddress!, pcmF32.count)
            }
        }
        return (outData, state.currentGain)
    }

    /// Snapshot current gain — used by diagnostic logging.
    public var currentGain: Float { state.currentGain }
    /// Snapshot current long-term RMS — used by diagnostic logging.
    public var longTermRMS: Double { state.longTermRMS }
}
