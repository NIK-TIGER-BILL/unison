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

    /// Below this queue depth the rate stays at 1.0 (no speedup).
    private static let targetQueueSec: Double = 0.4
    /// At or above this queue depth the rate clamps to `maxRate`.
    /// Between target and panic the rate scales linearly.
    private static let panicQueueSec: Double = 1.0
    /// Hard ceiling on the rate — above ~1.15 speech starts sounding
    /// audibly artefacted from time-stretching.
    private static let maxRate: Float = 1.15
    /// Smoothing factor on rate updates: each tick moves the rate
    /// halfway toward the target so changes are gradual, not stepped.
    private static let smoothing: Float = 0.5
    /// Re-log the rate when it has moved by at least this much from
    /// the last logged value, to keep the diagnostic noise bounded.
    private static let logHysteresis: Float = 0.03

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
        if queueSec >= Self.panicQueueSec {
            targetRate = Self.maxRate
        } else if queueSec <= Self.targetQueueSec {
            targetRate = 1.0
        } else {
            let t = Float((queueSec - Self.targetQueueSec) / (Self.panicQueueSec - Self.targetQueueSec))
            targetRate = 1.0 + t * (Self.maxRate - 1.0)
        }

        let currentRate = timePitch.rate
        let smoothed = currentRate + (targetRate - currentRate) * Self.smoothing
        timePitch.rate = smoothed

        if abs(smoothed - lastLoggedRate) >= Self.logHysteresis ||
            abs(queueSec - lastLoggedQueueSec) >= 0.5 {
            log.debug("[\(label)] pacing — queue=\(String(format: "%.2fs", queueSec)) rate=\(String(format: "%.3f", smoothed))")
            lastLoggedRate = smoothed
            lastLoggedQueueSec = queueSec
        }
    }
}
