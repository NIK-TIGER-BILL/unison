import Foundation
import AVFoundation
import UnisonDomain

/// Adaptive playback-rate controller for translation audio.
///
/// OpenAI Realtime returns translated PCM faster than wall-clock when
/// the model is responding; scheduling each chunk straight into an
/// `AVAudioPlayerNode` lets the node's internal queue grow unbounded.
/// On Bluetooth output the resulting clock skew + accumulated latency
/// were the most likely cause of the "translation gets quieter over
/// time and jumps in volume" report — the driver's rate-correction
/// path kicks in once the queue gets unreasonably deep.
///
/// This controller tracks "samples scheduled" against
/// `player.playerTime(forNodeTime:)` (which counts samples actually
/// pulled from the node) and ramps an `AVAudioUnitTimePitch`'s `rate`
/// up to `maxRate` to drain the backlog without dropping any audio.
/// Pitch is preserved — speech still sounds like the same voice, just
/// faster. The ramp uses hysteresis (`targetQueueSec` ↔ `panicQueueSec`)
/// so the rate doesn't oscillate around the boundary.
///
/// Owned by the player; one instance per `AVAudioPlayerNode` whose
/// output passes through the matching `AVAudioUnitTimePitch`. Call
/// `start()` once the engine + nodes are running, `didSchedule(samples:)`
/// after each `scheduleBuffer`, and `reset()` / `stop()` on the engine
/// stop path.
public final class PlaybackPacing: @unchecked Sendable {
    private let player: AVAudioPlayerNode
    private let timePitch: AVAudioUnitTimePitch
    private let sampleRate: Double
    private let log: UnisonLog
    private let label: String

    /// Below this queue depth the P-term is 0 (no speedup).
    static let targetQueueSec: Double = 0.2
    /// At or above this queue depth the P-term saturates to 1.0.
    static let panicQueueSec: Double = 1.5
    /// Hard ceiling on `timePitch.rate`. AVAudioUnitTimePitch supports
    /// much higher but speech becomes unintelligible past ~3x.
    static let maxRate: Double = 2.5
    /// Velocity coefficient. `D = clamp(velocity * kDerivative, ±derivativeClamp)`.
    static let kDerivative: Double = 1.5
    /// Hard limit on the D-term so a noisy velocity spike doesn't
    /// whiplash the rate.
    static let derivativeClamp: Double = 0.5
    /// Smoothing factor when the new target is higher than current —
    /// fast attack so bursts get caught quickly.
    static let attackFactor: Double = 0.7
    /// Smoothing factor when the new target is lower than current —
    /// slow release so we keep eating buffered audio before easing off.
    static let releaseFactor: Double = 0.15
    /// Polling interval for `tick()`. Velocity is computed as
    /// `(depth - prevDepth) / tickIntervalSec` assuming the constant
    /// — Task.sleep jitter (±10ms) is masked by the smoothing pass.
    static let tickIntervalSec: Double = 0.1
    /// Re-log when rate or queue has moved beyond this delta. Keeps
    /// the diagnostic noise bounded.
    static let logHysteresis: Double = 0.03

    // TODO(pacing-v2-task-4): remove these v1 aliases when tick() is rewritten
    private static let v1TargetQueueSec: Double = 0.4
    private static let v1PanicQueueSec: Double = 1.0
    private static let v1MaxRate: Float = 1.15

    // TODO(pacing-v2-task-4): remove once tick() is rewritten
    private static let smoothing: Float = 0.5

    /// Result of one pacing calculation. Decomposed so the diagnostic
    /// log can show why the rate is what it is (which term dominated).
    struct RateState: Equatable {
        let target: Double
        let p: Double
        let d: Double
    }

    /// Pure rate-target computation. Combines a proportional term
    /// (how far above `targetQueueSec` we are) with a derivative term
    /// (how fast the queue is growing or draining), clamps the result
    /// into `[1.0, maxRate]`. Returns the raw unsmoothed target — the
    /// caller applies asymmetric smoothing (via `attackFactor`/`releaseFactor` — added in Task 3).
    static func computeRate(depth: Double, velocity: Double) -> RateState {
        let pNum = max(0.0, depth - targetQueueSec)
        let p = min(1.0, pNum / (panicQueueSec - targetQueueSec))
        let d = max(-derivativeClamp, min(derivativeClamp, velocity * kDerivative))
        let raw = 1.0 + (p + d) * (maxRate - 1.0)
        let target = min(maxRate, max(1.0, raw))
        return RateState(target: target, p: p, d: d)
    }

    /// One-tick smoothing step. Pulls `currentRate` toward `target`
    /// using `attackFactor` when ramping up (we want to catch bursts
    /// quickly) and `releaseFactor` when ramping down (we want to
    /// hold the elevated rate briefly so any residual buffered audio
    /// finishes draining before we let off).
    static func smoothed(currentRate: Double, target: Double) -> Double {
        let factor = target > currentRate ? attackFactor : releaseFactor
        return currentRate + (target - currentRate) * factor
    }

    private let lock = NSLock()
    private var scheduledSamples: AVAudioFramePosition = 0
    private var ticker: Task<Void, Never>?
    private var lastLoggedRate: Float = 1.0
    private var lastLoggedQueueSec: Double = 0

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

    /// Account for samples just queued via `scheduleBuffer`. Cheap;
    /// call from the schedule hot path.
    public func didSchedule(samples: AVAudioFramePosition) {
        lock.lock(); defer { lock.unlock() }
        scheduledSamples += samples
    }

    /// Begin polling queue depth and adjusting `timePitch.rate`. Idempotent
    /// — calling twice replaces the previous tick task.
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

    /// Zero the scheduled-samples counter and the timePitch rate. Call
    /// at the start of each `play(_:)` invocation so a stop-restart
    /// cycle doesn't carry a stale backlog into the new session.
    public func reset() {
        lock.lock()
        scheduledSamples = 0
        lock.unlock()
        timePitch.rate = 1.0
        lastLoggedRate = 1.0
        lastLoggedQueueSec = 0
    }

    private func tick() {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return }
        lock.lock()
        let queuedSamples = max(0, scheduledSamples - playerTime.sampleTime)
        lock.unlock()
        let queueSec = Double(queuedSamples) / sampleRate

        let targetRate: Float
        if queueSec >= Self.v1PanicQueueSec {
            targetRate = Self.v1MaxRate
        } else if queueSec <= Self.v1TargetQueueSec {
            targetRate = 1.0
        } else {
            let t = Float((queueSec - Self.v1TargetQueueSec) / (Self.v1PanicQueueSec - Self.v1TargetQueueSec))
            targetRate = 1.0 + t * (Self.v1MaxRate - 1.0)
        }

        let currentRate = timePitch.rate
        let smoothed = currentRate + (targetRate - currentRate) * Self.smoothing
        timePitch.rate = smoothed

        if abs(smoothed - lastLoggedRate) >= Float(Self.logHysteresis) ||
            abs(queueSec - lastLoggedQueueSec) >= 0.5 {
            log.debug("[\(label)] pacing — queue=\(String(format: "%.2fs", queueSec)) rate=\(String(format: "%.3f", smoothed))")
            lastLoggedRate = smoothed
            lastLoggedQueueSec = queueSec
        }
    }
}
