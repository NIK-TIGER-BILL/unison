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
/// **v5 — asymmetric "never slow, gently drain" (replaces v4's
/// bidirectional regulator).** Offline replay of a *real* recorded arrival
/// timeline (`pacing-eval`) showed v4 underran 3% of ticks in 8 distinct
/// windows AND let the buffer balloon to ~960 ms, while a plain fixed 1.0×
/// had ZERO underruns. The culprit was v4 itself: it set the target rate
/// from `arrivalRateEMA + correction` through a slow (τ≈2 s) depth
/// smoother, so on a burst it sped up — draining the cushion right before
/// the next inter-chunk gap (the audible micropause) — and its 0.85× floor
/// stretched audio at the wrong moments (the "robotic" artefact). Both
/// symptoms the user reported were *our controller*, not the network.
///
/// v5 reacts only to the **actual** measured backlog. Baseline is a
/// pitch-perfect 1.0×; the rate only ever *increases* (never below 1.0×),
/// and only gently (ceiling `maxRate` 1.15×), to drain a buffer that has
/// grown past `targetBufferSec` (0.30 s, ≈ the observed p90 inter-chunk
/// jitter). A faster depth smoother (`depthSmoothAlpha` 0.15, τ≈0.6 s)
/// tracks sub-second bursts. On the same real timeline this cut underruns
/// to a single unavoidable window (a 505 ms network gap after a model
/// slowdown), capped peak latency at 550 ms, held the rate in [1.00,1.05]×
/// (no audible time-stretch), and kept mean latency unchanged (~315 ms).
///
/// **Invariants enforced.**
/// 1. `1.0 == minRate <= timePitch.rate <= maxRate`. The floor is exactly
///    1.0 — slowing below real-time builds latency AND adds time-stretch
///    artefacts (v4's mistake); the ceiling gently drains bursts.
/// 2. Rate changes are slew-limited to `maxRateStepPerTick` (0.05 = 0.5
///    per second) — imperceptible inside a single chunk.
///
/// **What this does NOT solve.** If the model emits slower than real-time
/// for a *sustained* stretch the buffer drains and underruns — playing at
/// 1.0× cannot invent audio that hasn't arrived, and we deliberately do
/// NOT slow below 1.0× to paper over it (that re-introduces the robotic
/// artefact for a worse trade). Observed arrival averages ≈1.0× with
/// jitter, so this is rare; the residual gap is left briefly audible
/// rather than smeared across the whole utterance. Bluetooth driver clock
/// skew still lives below this controller; the model's amplitude fade is
/// handled by `CompensatingAGC`, not here.
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

    /// Jitter-buffer **cushion ceiling** in audio-seconds. The controller
    /// plays a pitch-perfect 1.0× whenever the queue sits **at or below**
    /// this — i.e. it HOLDS the cushion the model's bursts build up — and
    /// only ever speeds up to *drain* the queue back down when it grows
    /// ABOVE this (a runaway-latency cap, not a target it chases). So this
    /// is the latency you trade for jitter protection: bigger = more held
    /// cushion = fewer freezes, more steady-state delay.
    ///
    /// **Why 1.0 s (0.30 and 0.60 were both too thin — a real bug).**
    /// Real-session logs (2026-06-30) caught the controller speeding up to
    /// ~1.08× to drain a *healthy* 0.5 s buffer down toward the thin 0.30 s
    /// setpoint — **emptying the jitter cushion right before the next gap**,
    /// so the player ran dry (the freeze). It even did this while the model
    /// was delivering on time: a thin setpoint makes the controller trim
    /// the very buffer it needs, then underrun, rebuild, and trim again.
    /// Raising the ceiling to ~1.0 s means a 0.3–0.9 s cushion is now HELD
    /// (played at 1.0×, never trimmed), which absorbs the model's typical
    /// 0.3–0.8 s arrival jitter. Above ~1.0 s the controller is replaying
    /// the frontier's flat region — extra ceiling stops helping (the
    /// residual freezes are sustained model slowdowns, not single gaps) —
    /// so 1.0 s is the knee.
    ///
    /// **Default 0.5 s.** Once the *source* of the big gaps is fixed — the
    /// Gemini VAD `silenceDurationMs` (was sitting through the API's ~800 ms
    /// default before emitting each clause; see `GeminiSetupPayload`) — the
    /// arrival gaps shrink to fit a thin cushion, so a 500 ms buffer can be
    /// glitch-free without the latency a 1 s cushion cost. Override live with
    /// `UNISON_BUFFER_MS` (=1000 if a network is still jittery, =300 for
    /// minimum latency). We do NOT stretch audio to bridge a stall longer
    /// than the cushion (that re-introduces the "robotic" artefact).
    public static let targetBufferSec: Double = {
        if let raw = ProcessInfo.processInfo.environment["UNISON_BUFFER_MS"],
           let ms = Double(raw), ms >= 0 {
            return ms / 1000.0
        }
        return 0.5
    }()
    /// Hard ceiling on `timePitch.rate`. v5 caps the drain at a GENTLE
    /// 1.15× (was 1.5×): the user reported "robotic" audio, and TimePitch
    /// above ~1.15× is audibly time-stretched. v5 only ever speeds up to
    /// drain, so this ceiling bounds the worst-case artefact; on real data
    /// the rate never exceeded ~1.05×, so 1.15× is pure safety headroom
    /// for an unusually large burst.
    public static let maxRate: Double = 1.15
    /// Floor on `timePitch.rate`. v5 pins this at **exactly 1.0×**: the
    /// player never plays slower than real-time. v4's sub-1.0 floor (0.85)
    /// was meant to bridge sub-real-time arrival by stretching audio, but
    /// real-data replay showed it (a) added latency and (b) produced the
    /// "robotic" time-stretch artefact the user reported — for *zero*
    /// underrun benefit vs. a hard 1.0 floor, because by the time the slow
    /// depth smoother reacts the buffer is already empty and there is
    /// nothing left to stretch. So we don't slow at all: a genuine
    /// model-slowdown gap is left briefly audible, not smeared.
    public static let minRate: Double = 1.0
    /// Multiplier on `(depth_smooth - targetBufferSec)` to translate
    /// buffer error into a rate correction. 0.4 drains gently: a buffer
    /// 0.25 s over target → +0.10 rate (1.10×, imperceptible) that bleeds
    /// the excess off over a couple of seconds. Below target the negative
    /// correction is clamped away by the 1.0× floor (we never slow), so
    /// this gain only ever governs how briskly we drain a too-full buffer.
    public static let correctionGain: Double = 0.4
    /// Maximum change in `timePitch.rate` per tick. At a 100 ms tick
    /// interval, 0.05 means the rate can move at most 0.5 per second
    /// — well below the threshold of audible glitching on TimePitch.
    public static let maxRateStepPerTick: Double = 0.05
    /// EMA coefficient for the depth smoother. v5 uses 0.15 (τ ≈ 0.6 s),
    /// 3× faster than v4's 0.05 (τ ≈ 2 s). The slow v4 smoother was a root
    /// cause of the micropauses: it tracked the buffer so sluggishly that
    /// the controller reacted to the *previous* burst/gap, draining the
    /// cushion right before the next gap. τ ≈ 0.6 s tracks the sub-second
    /// arrival jitter while still filtering single-chunk 0 ↔ 0.25 s
    /// impulses enough that the slew limit keeps the rate smooth.
    public static let depthSmoothAlpha: Double = 0.15
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

    /// Pure rate-target computation (v5, asymmetric). The target is
    /// `1.0 + correction` clamped to `[minRate, maxRate]` (= `[1.0, 1.15]`),
    /// where the correction is proportional to how far the *actual* smoothed
    /// backlog sits above the setpoint. The caller applies the slew-rate
    /// limit via `slewToward(currentRate:target:maxStep:)`.
    ///
    /// `arrivalRateEMA` is **intentionally not in the formula** — it is kept
    /// as a parameter only so the diagnostic tick log can report it. v4 used
    /// `arrivalRateEMA + correction`, predicting the drain from the long-run
    /// arrival rate; on real data that overshot on bursts and drained the
    /// cushion right before the next gap (the micropause). v5 reacts to the
    /// measured backlog alone, so it can only ever ask to speed *up* (the
    /// negative correction below target is clamped off by the 1.0× floor).
    public static func targetRate(arrivalRateEMA: Double, depthSmooth: Double) -> RateState {
        _ = arrivalRateEMA  // diagnostic-only; see doc comment for why it's out of the formula
        let bufferError = depthSmooth - targetBufferSec
        let correction = bufferError * correctionGain
        let unbounded = 1.0 + correction
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
    /// True while the queue is currently dry (underrunning), so each
    /// distinct dry spell logs one `[UNDERRUN]` line, not one per tick.
    private var wasDry = false
    /// Previous-tick snapshots for per-tick arrival and consumption
    /// rates. Both are reset to 0 on each `reset()`.
    private var prevScheduledForRate: AVAudioFramePosition = 0
    private var prevCompletedForRate: AVAudioFramePosition = 0
    /// Smoothed (EMA) arrival rate. **Diagnostic-only in v5** — it is
    /// logged so the dump shows the wall-clock ratio the server emits at
    /// (≈ 1.0× for real-time speakers, higher during clause-bursts), but it
    /// no longer feeds the rate decision (see `targetRate`). Kept because a
    /// sustained arrival ≠ 1.0× in the logs is the signal that would
    /// justify revisiting the "never slow below 1.0×" policy.
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
    ///
    /// Holds the full lock — `reset()` is called from the consumer task
    /// (different thread from the `ticker` Task that runs `tick()`),
    /// so we need to publish all writes atomically.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        scheduledSamples = 0
        completedSamples = 0
        prevScheduledForRate = 0
        prevCompletedForRate = 0
        appliedRate = 1.0
        lastLoggedRate = 1.0
        lastLoggedQueueSec = 0
        tickCount = 0
        wasDry = false
        arrivalRateEMA = 1.0
        consumptionRateEMA = 1.0
        depthSmooth = 0
        // `timePitch.rate` is an `AVAudioUnit` parameter — its setter is
        // documented thread-safe (atomically published to the render
        // block). Safe to touch outside the lock, but we're already
        // holding it so do it here for readability.
        timePitch.rate = 1.0
    }

    // MARK: - Tick

    private func tick() {
        // The entire body runs under the lock — `tick()` fires on the
        // async ticker Task while `reset()` runs on the consumer Task
        // and `didSchedule`/`didComplete` run on schedule callers
        // (including CoreAudio render threads). Bare scalar reads/writes
        // across these threads would race; the lock is cheap (the body
        // is a few µs at most) so we hold it for the whole call.
        lock.lock(); defer { lock.unlock() }

        tickCount += 1
        let scheduledSnapshot = scheduledSamples
        let completedSnapshot = completedSamples
        let scheduledDelta = scheduledSnapshot - prevScheduledForRate
        let completedDelta = completedSnapshot - prevCompletedForRate
        prevScheduledForRate = scheduledSnapshot
        prevCompletedForRate = completedSnapshot
        let queuedSamples = max(0, scheduledSnapshot - completedSnapshot)
        let depth = Double(queuedSamples) / sampleRate

        // Per-tick instantaneous rates as dimensionless ratios
        // (audio-seconds per wall-clock-second).
        let dtSamples = Self.tickIntervalSec * sampleRate
        let instantArrival = Double(scheduledDelta) / dtSamples
        let instantConsumption = Double(completedDelta) / dtSamples

        // Update EMAs. `consumptionRateEMA` is diagnostic-only — it's
        // logged but doesn't feed the rate decision. Kept here so the
        // diagnostic dump shows whether the actual consumption rate
        // (= timePitch.rate × base) matches the arrival rate.
        arrivalRateEMA += (instantArrival - arrivalRateEMA) * Self.arrivalRateAlpha
        consumptionRateEMA += (instantConsumption - consumptionRateEMA) * Self.arrivalRateAlpha
        depthSmooth += (depth - depthSmooth) * Self.depthSmoothAlpha

        // --- Underrun (dry-queue) detection — authoritative micropause signal.
        // `depth` is the real scheduled-minus-completed backlog (driven by
        // the .dataPlayedBack completion callbacks), so `depth ≈ 0` while
        // we were recently playing (`depthSmooth` still warm) means the
        // player has drained its queue and is emitting silence — exactly
        // the audible micropause the user reports. One info line per spell
        // (hysteresis via `wasDry`); the `depthSmooth` guard suppresses the
        // benign depth=0 at session start/end. Cross-reference `[audio-rx]`
        // (model late?), `[pump]` (MainActor stall?), `[sched-stall]`.
        let isDry = depth < 0.005 && depthSmooth > 0.03
        if isDry && !wasDry {
            log.info("[UNDERRUN \(label)] queue DRY — player starved mid-stream"
                + " (depth_smooth=\(String(format: "%.3fs", depthSmooth))"
                + " arrival_ema=\(String(format: "%.3fx", arrivalRateEMA))"
                + " applied_rate=\(String(format: "%.3f", appliedRate))) — audible micropause")
        }
        wasDry = isDry

        // Compute target and slew toward it.
        let state = Self.targetRate(arrivalRateEMA: arrivalRateEMA, depthSmooth: depthSmooth)
        appliedRate = Self.slewToward(currentRate: appliedRate,
                                      target: state.clampedTarget,
                                      maxStep: Self.maxRateStepPerTick)
        timePitch.rate = Float(appliedRate)

        // DIAG: log every 10th tick (1 s) at debug level so the
        // steady-state arrival/consumption ratio and the rate's
        // progression are visible without flooding the user-facing
        // log. Bump to info if actively debugging pacing.
        if tickCount % 10 == 0 {
            let tickLine = "[\(label)] pacing tick=\(tickCount)"
                + " depth=\(String(format: "%.3fs", depth))"
                + " depth_smooth=\(String(format: "%.3fs", depthSmooth))"
                + " arrival_ema=\(String(format: "%.3fx", arrivalRateEMA))"
                + " consumption_ema=\(String(format: "%.3fx", consumptionRateEMA))"
                + " target=\(String(format: "%.3f", state.clampedTarget))"
                + " applied=\(String(format: "%.3f", appliedRate))"
            log.debug(tickLine)
        }

        if abs(appliedRate - lastLoggedRate) >= Self.logHysteresis ||
            abs(depth - lastLoggedQueueSec) >= 0.5 {
            let changeLine = "[\(label)] pacing — queue=\(String(format: "%.2fs", depth))"
                + " arrival=\(String(format: "%.2fx", arrivalRateEMA))"
                + " target=\(String(format: "%.3f", state.clampedTarget))"
                + " applied=\(String(format: "%.3f", appliedRate))"
                + " bufErr=\(String(format: "%+.2f", state.bufferError))"
            log.debug(changeLine)
            lastLoggedRate = appliedRate
            lastLoggedQueueSec = depth
        }
    }
}
