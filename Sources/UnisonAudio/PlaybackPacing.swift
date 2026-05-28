import Foundation
import AVFoundation
import UnisonDomain

/// Adaptive playback-rate controller for translation audio (v3).
///
/// **Why v3 exists.** v1 (`maxRate=1.15`, linear interpolation) was too
/// timid — buffer grew on long bursts. v2 (P+D with `maxRate=2.5`) ran
/// the rate to 1.7–2.0× even when arrival rate was only 1.0× real-time,
/// emptying the buffer between chunks and producing the "word-by-word
/// with pauses" symptom the user reported. Empirical measurement (see
/// the `arrival_ema` diag logs) showed the model emits at ≈ 1.0× wall-
/// clock for our test speaker, with brief clause-bursts to ~1.5×. The
/// v2 P+D controller had no way to know the long-run arrival rate, so
/// it treated every per-chunk impulse as if the queue were exploding.
///
/// **v3 model.** Track the long-run arrival rate as an EMA. Track the
/// queue depth as a slow EMA so per-chunk impulses don't dominate.
/// Compute the player's target rate as `arrival_rate + buffer_correction`
/// where the correction is proportional to "buffer too full" vs "buffer
/// too empty". Then slew-rate-limit the change so the rate moves
/// smoothly (under 0.5/sec) and is imperceptible inside a single chunk.
///
/// **Invariants enforced.**
/// 1. `timePitch.rate >= 1.0` always — never play slower than real-time.
///    Anything slower would let the buffer overflow forever.
/// 2. `timePitch.rate <= maxRate` (2.5) — above that TimePitch artefacts
///    become audible on speech.
/// 3. Rate changes are slew-limited to `maxRateStepPerTick` (0.05 = 0.5
///    per second). At a 100 ms tick interval this is imperceptible
///    inside a single ~400 ms chunk.
///
/// **What this does NOT solve.** Bluetooth driver clock skew, per-chunk
/// network jitter, and the model's clause-burst timing all live below
/// this controller. The pacing keeps the queue *bounded* and the
/// playback *smooth* — but if the model ever genuinely emits slower
/// than 1.0× for a sustained period (unlikely but possible), the
/// buffer must underrun because we can't go below 1.0×.
///
/// Owned by the player; one instance per `AVAudioPlayerNode` whose
/// output passes through the matching `AVAudioUnitTimePitch`. Call
/// `start()` once the engine + nodes are running, `didSchedule(samples:)`
/// after each `scheduleBuffer`, hook the buffer's completion handler to
/// `didComplete(samples:)`, and `reset()` / `stop()` on the engine
/// stop path.
public final class PlaybackPacing: @unchecked Sendable {
    private let player: AVAudioPlayerNode
    private let timePitch: AVAudioUnitTimePitch
    private let sampleRate: Double
    private let log: UnisonLog
    private let label: String

    // MARK: - Constants
    //
    // These constants are `public` so the offline simulator
    // (`pacing-eval` CLI in Sources/Tools/PacingEval) can drive a
    // headless replay through the same numbers the production
    // controller uses. There's no other reason to expose them and
    // the in-app callers don't reach for them.

    /// Desired steady-state buffer depth in audio-seconds. Acts as the
    /// "we don't care below this" threshold — at the empirically-
    /// observed average buffer depth (0.08–0.15 s on real OpenAI
    /// translation sessions), rate stays at 1.0× and the controller
    /// is a no-op. Pushed up to 1.0 s after harness data showed v3's
    /// previous 0.4 s threshold triggered mild speedups (rate up to
    /// 1.18×) that drained the buffer fast enough to create the
    /// "empty window between chunks" pattern the user reported.
    public static let targetBufferSec: Double = 1.0
    /// Hard ceiling on `timePitch.rate`. Capped at 1.5× — TimePitch
    /// supports much higher, but our policy is "stay close to real-
    /// time playback unless the model is truly overflowing". 1.5×
    /// is still audibly natural; higher values introduce noticeable
    /// time-stretch artefacts.
    public static let maxRate: Double = 1.5
    /// Hard floor on `timePitch.rate`. Below 1.0 the player falls behind
    /// real-time and the buffer overflows indefinitely; we never go
    /// slower than wall-clock even if the buffer is empty.
    public static let minRate: Double = 1.0
    /// Multiplier on `(depth_smooth - targetBufferSec)` to translate
    /// buffer error into a rate correction. Tuned so a 3 s buffer
    /// depth (excess = 2.0) lands exactly at `maxRate=1.5` from a 1.0
    /// baseline: `1.0 + 2.0 × 0.3 = 1.6` → clamps to 1.5. The 0.3
    /// gain keeps the ramp gentle — the rate changes smoothly across
    /// several seconds rather than jerking on each depth peak.
    public static let correctionGain: Double = 0.3
    /// Maximum change in `timePitch.rate` per tick. At a 100 ms tick
    /// interval, 0.05 means the rate can move at most 0.5 per second
    /// — well below the threshold of audible glitching on TimePitch.
    public static let maxRateStepPerTick: Double = 0.05
    /// EMA coefficient for the depth smoother. With `dt=0.1s` this is
    /// `1 - exp(-dt/τ)` for τ ≈ 2 s, i.e. ≈ 0.05. Long enough to filter
    /// per-chunk 0 ↔ 0.4 oscillation, short enough to respond to a
    /// genuine clause-burst within a couple of seconds.
    public static let depthSmoothAlpha: Double = 0.05
    /// EMA coefficient for the arrival-rate tracker. τ ≈ 5 s — long
    /// enough to track a steady speaker pace, short enough to adapt
    /// when the speaker changes cadence.
    public static let arrivalRateAlpha: Double = 0.02
    /// Polling interval for `tick()`.
    public static let tickIntervalSec: Double = 0.1
    /// Re-log only when the rate or buffer has moved beyond these
    /// deltas, to keep diagnostic noise bounded.
    public static let logHysteresis: Double = 0.03

    // MARK: - Pure rate computation

    /// Decomposed snapshot of one pacing tick. Returned by `targetRate`
    /// and consumed by the diagnostic log and the slew step.
    public struct RateState: Equatable {
        /// Buffer-depth error: `depth_smooth - targetBufferSec`. Positive
        /// means "buffer too full → speed up"; negative means "buffer
        /// too empty → slow down toward floor".
        public let bufferError: Double
        /// Rate correction proportional to buffer error.
        public let correction: Double
        /// Raw target before clamping: `arrival + correction`.
        public let unboundedTarget: Double
        /// Final target after clamping to `[minRate, maxRate]`. The
        /// slew step pulls `applied_rate` toward this value.
        public let clampedTarget: Double

        public init(bufferError: Double, correction: Double, unboundedTarget: Double, clampedTarget: Double) {
            self.bufferError = bufferError
            self.correction = correction
            self.unboundedTarget = unboundedTarget
            self.clampedTarget = clampedTarget
        }
    }

    /// Pure rate-target computation. Combines a long-run arrival-rate
    /// estimate with a buffer-error correction, then clamps the result
    /// to `[minRate, maxRate]`. The caller applies the slew-rate limit
    /// via `slewToward(currentRate:target:maxStep:)`.
    public static func targetRate(arrivalRateEMA: Double, depthSmooth: Double) -> RateState {
        let bufferError = depthSmooth - targetBufferSec
        let correction = bufferError * correctionGain
        let unbounded = arrivalRateEMA + correction
        let clamped = min(maxRate, max(minRate, unbounded))
        return RateState(
            bufferError: bufferError,
            correction: correction,
            unboundedTarget: unbounded,
            clampedTarget: clamped
        )
    }

    /// One-tick slew step. Pulls `currentRate` toward `target` by at
    /// most `maxStep` (in either direction). Keeps rate changes
    /// imperceptibly gradual: at the default `maxRateStepPerTick=0.05`
    /// and `tickIntervalSec=0.1`, the rate can move at most 0.5 per
    /// second.
    public static func slewToward(currentRate: Double, target: Double, maxStep: Double) -> Double {
        let delta = target - currentRate
        let clampedDelta = max(-maxStep, min(maxStep, delta))
        return currentRate + clampedDelta
    }

    // MARK: - Stored state

    private let lock = NSLock()
    private var scheduledSamples: AVAudioFramePosition = 0
    /// Running total of samples the player has consumed from its scheduled
    /// queue. Bumped by `didComplete(samples:)` from each `scheduleBuffer`
    /// completion handler. The pair (`scheduledSamples`, `completedSamples`)
    /// gives the genuine queue depth without leaking the engine's
    /// pre-first-buffer silence (which `playerTime.sampleTime` would have
    /// included and overrun us with — see the type doc comment for why).
    private var completedSamples: AVAudioFramePosition = 0
    private var ticker: Task<Void, Never>?
    private var lastLoggedRate: Double = 1.0
    private var lastLoggedQueueSec: Double = 0
    /// DIAG: tick counter so we can force-log every Nth tick at info level.
    private var tickCount: Int = 0
    /// Previous-tick snapshots for per-tick arrival and consumption
    /// rates. Both are reset to 0 on each `reset()`.
    private var prevScheduledForRate: AVAudioFramePosition = 0
    private var prevCompletedForRate: AVAudioFramePosition = 0
    /// Smoothed (EMA) arrival rate. Calibrates the steady-state player
    /// rate: a healthy session converges this to the average wall-clock
    /// ratio the server is emitting at (≈ 1.0× for real-time speakers,
    /// 1.2–1.5× during clause-bursts).
    private var arrivalRateEMA: Double = 1.0
    /// Smoothed (EMA) consumption rate. Tracked for diagnostics so we
    /// can verify arrival ≈ consumption in steady state.
    private var consumptionRateEMA: Double = 1.0
    /// Smoothed (EMA) buffer depth in audio-seconds. The pacing
    /// controller reads this instead of the instantaneous depth so
    /// per-chunk 0 ↔ 0.4 s impulses don't dominate the rate.
    private var depthSmooth: Double = 0
    /// The player's currently-applied rate, kept in Double for slew
    /// arithmetic. Written to `timePitch.rate` as `Float` on each tick.
    private var appliedRate: Double = 1.0

    // MARK: - Init / lifecycle

    /// - parameter label: short tag for log lines (e.g. "speakers",
    ///   "blackhole2ch") so the two pacing controllers can be told
    ///   apart in the diagnostic dump.
    public init(player: AVAudioPlayerNode,
                timePitch: AVAudioUnitTimePitch,
                sampleRate: Double = 48_000,
                log: UnisonLog,
                label: String) {
        self.player = player
        self.timePitch = timePitch
        self.sampleRate = sampleRate
        self.log = log
        self.label = label
    }

    // MARK: - Public API

    /// Account for samples just queued via `scheduleBuffer`. Cheap;
    /// call from the schedule hot path.
    public func didSchedule(samples: AVAudioFramePosition) {
        lock.lock(); defer { lock.unlock() }
        scheduledSamples += samples
    }

    /// Account for samples just consumed by the player. Called from the
    /// `scheduleBuffer` completion handler, which fires on a CoreAudio
    /// render thread — must be lock-protected since `tick()` reads the
    /// counter from the async ticker Task.
    public func didComplete(samples: AVAudioFramePosition) {
        lock.lock(); defer { lock.unlock() }
        completedSamples += samples
    }

    /// Begin polling buffer depth and adjusting `timePitch.rate`.
    /// Idempotent — calling twice replaces the previous tick task.
    public func start() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.tick()
            }
        }
    }

    /// Stop the polling task. Call from the engine-stop path so the
    /// controller doesn't outlive the player's render context.
    public func stop() {
        ticker?.cancel()
        ticker = nil
    }

    /// Reset all counters and EMAs. Call at the start of each `play(_:)`
    /// invocation so a stop-restart cycle doesn't carry stale state.
    public func reset() {
        lock.lock()
        scheduledSamples = 0
        completedSamples = 0
        prevScheduledForRate = 0
        prevCompletedForRate = 0
        lock.unlock()
        timePitch.rate = 1.0
        appliedRate = 1.0
        lastLoggedRate = 1.0
        lastLoggedQueueSec = 0
        tickCount = 0
        arrivalRateEMA = 1.0
        consumptionRateEMA = 1.0
        depthSmooth = 0
    }

    // MARK: - Tick

    private func tick() {
        tickCount += 1
        lock.lock()
        let scheduledSnapshot = scheduledSamples
        let completedSnapshot = completedSamples
        let scheduledDelta = scheduledSnapshot - prevScheduledForRate
        let completedDelta = completedSnapshot - prevCompletedForRate
        prevScheduledForRate = scheduledSnapshot
        prevCompletedForRate = completedSnapshot
        let queuedSamples = max(0, scheduledSnapshot - completedSnapshot)
        let depth = Double(queuedSamples) / sampleRate
        lock.unlock()

        // Per-tick instantaneous rates as dimensionless ratios
        // (audio-seconds per wall-clock-second).
        let dtSamples = Self.tickIntervalSec * sampleRate
        let instantArrival = Double(scheduledDelta) / dtSamples
        let instantConsumption = Double(completedDelta) / dtSamples

        // Update EMAs.
        arrivalRateEMA += (instantArrival - arrivalRateEMA) * Self.arrivalRateAlpha
        consumptionRateEMA += (instantConsumption - consumptionRateEMA) * Self.arrivalRateAlpha
        depthSmooth += (depth - depthSmooth) * Self.depthSmoothAlpha

        // Compute target and slew toward it.
        let state = Self.targetRate(arrivalRateEMA: arrivalRateEMA, depthSmooth: depthSmooth)
        appliedRate = Self.slewToward(currentRate: appliedRate,
                                      target: state.clampedTarget,
                                      maxStep: Self.maxRateStepPerTick)
        timePitch.rate = Float(appliedRate)

        // DIAG: log every 10th tick (1 s) at info level so the steady-state
        // arrival/consumption ratio and the rate's progression are
        // visible without per-chunk noise.
        if tickCount % 10 == 0 {
            log.info("[\(label)] pacing tick=\(tickCount) depth=\(String(format: "%.3fs", depth)) depth_smooth=\(String(format: "%.3fs", depthSmooth)) arrival_ema=\(String(format: "%.3fx", arrivalRateEMA)) consumption_ema=\(String(format: "%.3fx", consumptionRateEMA)) target=\(String(format: "%.3f", state.clampedTarget)) applied=\(String(format: "%.3f", appliedRate))")
        }

        if abs(appliedRate - lastLoggedRate) >= Self.logHysteresis ||
            abs(depth - lastLoggedQueueSec) >= 0.5 {
            log.debug("[\(label)] pacing — queue=\(String(format: "%.2fs", depth)) arrival=\(String(format: "%.2fx", arrivalRateEMA)) target=\(String(format: "%.3f", state.clampedTarget)) applied=\(String(format: "%.3f", appliedRate)) bufErr=\(String(format: "%+.2f", state.bufferError))")
            lastLoggedRate = appliedRate
            lastLoggedQueueSec = depth
        }
    }
}
