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
/// and only gently (ceiling `maxRate` 1.06×), to drain a buffer that has
/// grown past `targetBufferSec` (a 1.0 s deadband edge — see the
/// constant; below it the rate is held at exactly 1.0×, no draining). A
/// faster depth smoother (`depthSmoothAlpha` 0.15, τ≈0.6 s)
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
    /// Drain threshold (a **deadband edge**, NOT a setpoint we pull toward).
    /// While the queue depth is at or below this, the rate is held at **exactly
    /// 1.0×** — no time-stretch, no rate wobble — so the audio plays through
    /// untouched. Only when depth climbs ABOVE this does the controller speed
    /// up (gently) to cap runaway latency. The actual playback latency is the
    /// queue's *natural* depth (the model front-loads to ~0.5–0.75 s), NOT this
    /// number — this is just where draining kicks in.
    ///
    /// **Why 1.0 s (0.5 and 0.75 were both too low — same failure mode).**
    /// The threshold must sit ABOVE the queue's natural depth, or the
    /// controller spends its life draining the very cushion it needs. At 0.5
    /// (OpenAI natural depth 0.5–0.75 s) it drained nonstop at 1.04–1.15×,
    /// pumping the queue to ZERO ~15 % of ticks — the "cutting in and out".
    /// Raising to 0.75 fixed that for OpenAI, but the 2026-07-02 field log
    /// showed Gemini's natural depth reaches ~0.75–1.0 s: the controller sat
    /// just above the threshold again (rate 1.01–1.04× continuously — the
    /// TimePitch phase vocoder never at unity), and a 719 ms socket gap
    /// underran the pre-drained cushion. 1.0 s is also the knee of the
    /// measured freeze-vs-latency frontier (0.30 → 6.7 % freezes, 0.60 →
    /// 5.2 %, 1.0 → 3.8 %, flat above — the residue is sustained model
    /// slowdowns no cushion covers). Override live with `UNISON_BUFFER_MS`.
    public static let targetBufferSec: Double = {
        if let raw = ProcessInfo.processInfo.environment["UNISON_BUFFER_MS"],
           let ms = Double(raw), ms >= 0 {
            return ms / 1000.0
        }
        return 1.0
    }()
    /// Hard ceiling on `timePitch.rate`. Capped at a VERY gentle 1.06×: any
    /// time-stretch is an artefact, and the only job here is to bleed off a
    /// burst slowly, not to chase a setpoint. 1.06× is enough to out-pace the
    /// model's ~1.015× delivery (so latency can't run away) while staying
    /// near-inaudible. Earlier 1.15× let the controller slam the rate up and
    /// drain the queue to empty (the "on/off" artefact); keeping the ceiling
    /// this close to 1.0 means even a burst-drain is barely perceptible.
    public static let maxRate: Double = 1.06
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
    /// Multiplier on `(depth_smooth - targetBufferSec)` → rate correction.
    /// 0.15 (was 0.4) keeps draining barely perceptible: a queue 0.5 s past
    /// the threshold → +0.075 (clamped to the 1.06× ceiling), bleeding off
    /// over several seconds rather than slamming the rate up and emptying the
    /// queue. Below the threshold the negative correction is clamped away by
    /// the 1.0× floor, so the rate sits at EXACTLY 1.0 in the deadband — this
    /// gain only governs how gently we trim a genuinely too-full queue.
    public static let correctionGain: Double = 0.15
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

    /// Hard latency ceiling (audio-seconds). The rate controller (≤1.06×)
    /// can only bleed off sub-second jitter; a MULTI-second backlog — e.g.
    /// the model dumping tens of seconds of buffered audio in one burst the
    /// instant a slow network recovers — is un-drainable by rate alone
    /// (1.06× clears ~1 s per 17 s), so playback sits permanently seconds
    /// behind live ("transcript updates but nothing is voiced" — the field
    /// bug: depth 0 → 33 s, arrival 5×). When the queue grows past this,
    /// `admit()` enters catch-up and the scheduler DROPS frames until the
    /// queue drains to `catchUpFloorSec`, resyncing to live. Set well above
    /// the normal held cushion (`targetBufferSec` + jitter, <1 s) so ordinary
    /// clause-bursts never trip it. Env override: UNISON_MAX_LATENCY_MS.
    public static let catchUpCeilingSec: Double = {
        if let raw = ProcessInfo.processInfo.environment["UNISON_MAX_LATENCY_MS"],
           let ms = Double(raw), ms > 0 { return ms / 1000.0 }
        return 2.5
    }()
    /// Low-water mark (audio-seconds): catch-up stops dropping once the queue
    /// has drained back to here, leaving a small live cushion. The gap to
    /// `catchUpCeilingSec` is hysteresis — without it a still-arriving burst
    /// would flip-flop admit/drop every frame.
    public static let catchUpFloorSec: Double = 0.5

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
        /// Raw target before clamping: `1.0 + correction` (v5 — arrival is not
        /// in the formula; see `targetRate`).
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
    /// `1.0 + correction` clamped to `[minRate, maxRate]` (= `[1.0, 1.06]`),
    /// where the correction is proportional to how far the *actual* smoothed
    /// backlog sits above the setpoint. The caller applies the slew-rate
    /// limit via `slewToward(currentRate:target:maxStep:)`.
    ///
    /// `arrivalRateEMA` is **intentionally not in the formula** and is ignored
    /// here — it's a v4 vestige kept in the signature only to avoid churning
    /// the callers (`tick()` and the `pacing-eval` replay harness), which still
    /// track and log the EMA separately for diagnostics. v4 used
    /// `arrivalRateEMA + correction`, predicting the drain from the long-run
    /// arrival rate; on real data that overshot on bursts and drained the
    /// cushion right before the next gap (the micropause). v5 reacts to the
    /// measured backlog alone, so it can only ever ask to speed *up* (the
    /// negative correction below target is clamped off by the 1.0× floor).
    public static func targetRate(arrivalRateEMA: Double, depthSmooth: Double) -> RateState {
        _ = arrivalRateEMA  // ignored in v5 (v4 vestige); see doc comment
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

    /// Pure catch-up hysteresis. Given the current backlog (`depthSec`) and
    /// whether we're already catching up, returns the NEW catching-up state.
    /// The scheduler drops the frame iff this returns true. Enter only when
    /// the backlog exceeds `catchUpCeilingSec` (a genuine burst); once in,
    /// keep dropping until it drains to `catchUpFloorSec`. The gap between
    /// the two thresholds prevents per-frame flip-flopping while a burst is
    /// still arriving.
    public static func catchUpDecision(depthSec: Double, catchingUp: Bool) -> Bool {
        catchingUp ? (depthSec > catchUpFloorSec) : (depthSec > catchUpCeilingSec)
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
    /// Last value actually written to `timePitch.rate`, so we can skip
    /// redundant re-writes of an unchanged rate (see `tick()`).
    private var lastWrittenRate: Float = 1.0
    /// Latch: true while we're dropping frames to catch up to live after a
    /// burst blew the queue past `catchUpCeilingSec`. Hysteresis state for
    /// `catchUpDecision`; reset in `reset()`.
    private var catchingUp = false

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

    /// Hard latency gate. Call BEFORE each `scheduleBuffer`; returns `false`
    /// when the queue is too far behind live (a burst) and the caller should
    /// DROP the frame instead of scheduling it, so playback resyncs to live
    /// rather than playing tens of seconds stale. Cheap — a lock + a compare;
    /// safe on the schedule hot path. The one transition log fires off-lock.
    public func admit() -> Bool {
        lock.lock()
        let depthSec = Double(max(0, scheduledSamples - completedSamples)) / sampleRate
        let next = Self.catchUpDecision(depthSec: depthSec, catchingUp: catchingUp)
        let transitioned = next != catchingUp
        catchingUp = next
        lock.unlock()
        if transitioned {
            if next {
                log.info("[\(label)] catch-up START — backlog \(String(format: "%.1f", depthSec))s blew past the \(String(format: "%.1f", Self.catchUpCeilingSec))s ceiling (burst after a stall); dropping stale audio to resync to live")
            } else {
                log.info("[\(label)] catch-up DONE — drained to \(String(format: "%.1f", depthSec))s; resumed live playback")
            }
        }
        return !next
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
        catchingUp = false
        // `timePitch.rate` is an `AVAudioUnit` parameter — its setter is
        // documented thread-safe (atomically published to the render
        // block). Safe to touch outside the lock, but we're already
        // holding it so do it here for readability.
        timePitch.rate = 1.0
        lastWrittenRate = 1.0
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
        // Only publish the rate parameter when it actually moved. v5 holds the
        // rate at exactly 1.0 in the deadband for long stretches; re-writing
        // the same value 10×/sec needlessly re-triggers the TimePitch phase-
        // vocoder's parameter-ramp handling (a plausible source of residual
        // texture). Write only on a meaningful change.
        let newRate = Float(appliedRate)
        if abs(newRate - lastWrittenRate) > 1e-4 {
            timePitch.rate = newRate
            lastWrittenRate = newRate
        }

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
