import Foundation
import UnisonAudio

/// Headless replay of `PlaybackPacing` against a recorded arrival
/// timeline. Reconstructs what the production controller would do if
/// the deltas had arrived at exactly the recorded timestamps and the
/// player had drained samples at the controller-dictated rate.
///
/// Why "simulator": building a real `AVAudioPlayerNode` per session is
/// expensive and brings TimePitch artefacts into the picture we don't
/// want here. The pacing controller is a pure-function-plus-state
/// system — we can drive it from the arrival timeline directly. The
/// completion handler is replaced by a virtual player that subtracts
/// `consumed_per_tick = rate × dt × sampleRate` from the queue each
/// tick.
struct PacingSimulator {
    let arrivals: [ArrivalRecord]
    /// Tick interval matching the production controller (100 ms).
    let tickInterval: TimeInterval = 0.1
    /// Sample rate of the player-side PCM. Production uses 48 kHz F32
    /// after the inbound Resampler upsampled 24 kHz → 48 kHz.
    /// The arrival samples are in 24 kHz int16 (2 bytes per sample), so
    /// we convert to 48 kHz sample count for fidelity with the real
    /// `didSchedule` argument.
    let playerSampleRate: Double = 48_000
    /// Pre-roll: don't start consuming audio until this many seconds of
    /// content has been buffered. Cheap one-time latency in exchange for
    /// headroom against inter-chunk gaps. 0 = play immediately on first
    /// delta. Default 0 (off) so the baseline matches production v3.
    var prerollSec: Double = 0
    /// Force-override the controller's output rate. When set, the
    /// pacing math still runs (we keep the EMA / depth-smooth
    /// bookkeeping for diagnostics) but `applied_rate` ignores it and
    /// holds at this value. Used to test "what if pacing didn't
    /// accelerate at all" against v3's mild ramp-up on depth peaks.
    var rateOverride: Double? = nil
    /// Variant tag for the report.
    var variantLabel: String = "v3-default"

    /// One row in the per-tick CSV output.
    struct TickRow {
        let t: TimeInterval
        let depth: Double            // raw depth (audio-seconds)
        let depthSmooth: Double
        let arrivalRateEMA: Double
        let consumptionRateEMA: Double
        let appliedRate: Double
        let targetRate: Double
        let bufferError: Double
        let underrun: Bool           // true if this tick we ran out of audio
    }

    struct Summary {
        let totalTicks: Int
        /// Ticks during which audio was *expected* to play — i.e. from
        /// the first arrival through the last arrival's audio duration.
        /// Underrun percentage is normalised to this window only,
        /// because counting silence after the model finished
        /// translating would inflate the figure for no good reason.
        let activeTicks: Int
        let underrunTicks: Int
        var underrunPercent: Double { Double(underrunTicks) / Double(max(1, activeTicks)) * 100.0 }
        let depthMin: Double
        let depthMax: Double
        let depthMeanWhenSpeaking: Double
        let rateMin: Double
        let rateMax: Double
        let rateMean: Double
        let arrivalRateMean: Double
        /// Wall-clock second at which the last scheduled sample left the
        /// player. This is the user-perceived end of playback — what we
        /// care about for "how much delay did the user actually hear".
        /// = `last_arrival_t + audio_duration_of_last_chunk` if the
        /// player kept pace at rate=1, slightly different if the rate
        /// drifted via the controller.
        let playbackFinishedAtSec: Double
    }

    func simulate() -> (rows: [TickRow], summary: Summary) {
        // Convert arrivals to a tick-indexed schedule of bytes-to-add.
        // For each arrival t, we add bytes to the queue at the matching
        // tick = floor(t / tickInterval).
        let lastT = arrivals.last?.t ?? 0
        // Extend simulation past the last arrival by enough to drain
        // the buffer at rate=1 even with all audio still queued. The
        // upper bound is `last_arrival_t + total_audio_seconds` (worst
        // case: buffer holds everything at last arrival, plays at 1x).
        let totalAudioSec = arrivals.reduce(0.0) { $0 + $1.audioDurationSec }
        let totalTicks = Int(ceil((lastT + totalAudioSec + 1.0) / tickInterval))
        var bytesPerTick = [Int](repeating: 0, count: totalTicks + 1)
        for a in arrivals {
            let i = max(0, min(bytesPerTick.count - 1, Int(a.t / tickInterval)))
            bytesPerTick[i] += a.bytes
        }

        // Pacing state (replicated from PlaybackPacing — kept in sync
        // with that file's `static let` constants).
        let targetBuffer = PlaybackPacing.targetBufferSec
        let maxRate = PlaybackPacing.maxRate
        let minRate = PlaybackPacing.minRate
        let depthAlpha = PlaybackPacing.depthSmoothAlpha
        let arrivalAlpha = PlaybackPacing.arrivalRateAlpha
        let maxStep = PlaybackPacing.maxRateStepPerTick

        var scheduledSamples: Double = 0   // in player samples (48 kHz)
        var completedSamples: Double = 0
        var depthSmooth: Double = 0
        var arrivalEMA: Double = 1.0
        var consumptionEMA: Double = 1.0
        var appliedRate: Double = 1.0

        var prevScheduled: Double = 0
        var prevCompleted: Double = 0
        // Pre-roll gate. We don't start consuming until the player has
        // either buffered prerollSec audio OR (defensively) the first
        // arrival is older than 2s — to avoid hanging forever if the
        // stream is sparse.
        var playbackStarted = prerollSec <= 0
        var firstArrivalTick: Int? = nil

        var rows: [TickRow] = []
        rows.reserveCapacity(totalTicks)

        // Stats accumulators
        var depthMin: Double = .infinity
        var depthMax: Double = 0
        var depthSumWhenSpeaking: Double = 0
        var depthSpeakingCount: Int = 0
        var rateMin: Double = .infinity
        var rateMax: Double = 0
        var rateSum: Double = 0
        var arrivalSum: Double = 0
        var underrunTicks: Int = 0
        /// Track the wall-clock at which the player most recently
        /// consumed actual audio. When the buffer drains and stays
        /// empty thereafter (no more arrivals), the last such tick
        /// marks `playbackFinishedAt`.
        var lastConsumeTick: Int = 0

        for tick in 0..<totalTicks {
            // Schedule arrivals for this tick. Bytes are 24kHz int16 →
            // samples = bytes / 2. Convert to player (48kHz) sample count
            // = double, matching how Resampler.fromOpenAIWire upsamples.
            let arrivedBytes = bytesPerTick[tick]
            let arrivedPlayerSamples = Double(arrivedBytes) / 2.0 * 2.0
            scheduledSamples += arrivedPlayerSamples
            if arrivedBytes > 0, firstArrivalTick == nil {
                firstArrivalTick = tick
            }

            // Pre-roll gate: hold off consumption until we've buffered
            // enough audio OR a fallback timeout (2s) elapsed since the
            // first arrival.
            if !playbackStarted, let firstTick = firstArrivalTick {
                let availableSamples = scheduledSamples - completedSamples
                let availableSec = availableSamples / playerSampleRate
                let elapsedSinceFirst = Double(tick - firstTick) * tickInterval
                if availableSec >= prerollSec || elapsedSinceFirst >= 2.0 {
                    playbackStarted = true
                }
            }

            // Consume audio from buffer at current applied rate.
            let dtSamples = tickInterval * playerSampleRate
            let wouldConsume = playbackStarted ? appliedRate * dtSamples : 0
            let available = scheduledSamples - completedSamples
            let actualConsumed = min(wouldConsume, available)
            completedSamples += actualConsumed
            // "Underrun" = we wanted to consume more than was available
            // AND playback has begun AND we're still in the window where
            // more audio is expected. Post-last-arrival silence isn't
            // underrun — it's the natural end of playback (the user
            // doesn't hear anything because there's nothing left to
            // translate, not because we glitched).
            //
            // Window: from `firstArrivalTick` up to and including
            // `Int(lastT / tickInterval) + audio_duration_of_last_chunk
            // / tickInterval` — i.e. through the playback of the last
            // arrived chunk. Beyond that, silence is expected.
            let currentTimeSec = Double(tick) * tickInterval
            let expectedAudioPresent = currentTimeSec <= lastT + 0.5
            let underrun = playbackStarted
                && actualConsumed < wouldConsume - 1e-6
                && firstArrivalTick != nil
                && firstArrivalTick! < tick
                && expectedAudioPresent

            // Compute depth + EMAs (replicating PlaybackPacing.tick exactly).
            let depth = max(0, scheduledSamples - completedSamples) / playerSampleRate
            let scheduledDelta = scheduledSamples - prevScheduled
            let completedDelta = completedSamples - prevCompleted
            prevScheduled = scheduledSamples
            prevCompleted = completedSamples

            let instantArrival = scheduledDelta / dtSamples
            let instantConsumption = completedDelta / dtSamples
            arrivalEMA += (instantArrival - arrivalEMA) * arrivalAlpha
            consumptionEMA += (instantConsumption - consumptionEMA) * arrivalAlpha
            depthSmooth += (depth - depthSmooth) * depthAlpha

            // Compute target via the production controller's pure fn.
            // Override allows us to A/B the controller against a fixed-
            // rate baseline (e.g. "what if we just always played at 1.0
            // and never tried to drain the buffer").
            let state = PlaybackPacing.targetRate(
                arrivalRateEMA: arrivalEMA,
                depthSmooth: depthSmooth
            )
            if let forced = rateOverride {
                appliedRate = forced
            } else {
                appliedRate = PlaybackPacing.slewToward(
                    currentRate: appliedRate,
                    target: state.clampedTarget,
                    maxStep: maxStep
                )
            }

            let t = Double(tick) * tickInterval
            rows.append(TickRow(
                t: t,
                depth: depth,
                depthSmooth: depthSmooth,
                arrivalRateEMA: arrivalEMA,
                consumptionRateEMA: consumptionEMA,
                appliedRate: appliedRate,
                targetRate: state.clampedTarget,
                bufferError: state.bufferError,
                underrun: underrun
            ))

            depthMin = min(depthMin, depth)
            depthMax = max(depthMax, depth)
            if scheduledSamples > 0 {  // only count once first audio arrived
                depthSumWhenSpeaking += depth
                depthSpeakingCount += 1
            }
            rateMin = min(rateMin, appliedRate)
            rateMax = max(rateMax, appliedRate)
            rateSum += appliedRate
            arrivalSum += arrivalEMA
            if underrun { underrunTicks += 1 }
            if actualConsumed > 0 { lastConsumeTick = tick }

            _ = targetBuffer; _ = maxRate; _ = minRate  // silence unused warnings, refs documenting which constants matter
        }

        // Active window for underrun normalisation: from the first
        // arrival's tick through Int(lastT/tickInterval) + a small
        // padding for the last chunk's duration.
        let firstTick = firstArrivalTick ?? 0
        let lastActiveTick = Int(lastT / tickInterval) + 5  // ~500ms padding
        let activeTicks = max(1, lastActiveTick - firstTick + 1)

        let summary = Summary(
            totalTicks: totalTicks,
            activeTicks: activeTicks,
            underrunTicks: underrunTicks,
            depthMin: depthMin == .infinity ? 0 : depthMin,
            depthMax: depthMax,
            depthMeanWhenSpeaking: depthSpeakingCount > 0 ? depthSumWhenSpeaking / Double(depthSpeakingCount) : 0,
            rateMin: rateMin == .infinity ? 1.0 : rateMin,
            rateMax: rateMax,
            rateMean: rateSum / Double(totalTicks),
            arrivalRateMean: arrivalSum / Double(totalTicks),
            playbackFinishedAtSec: Double(lastConsumeTick + 1) * tickInterval
        )

        return (rows, summary)
    }
}
