import Foundation
import UnisonDomain
import UnisonTranslation

/// One recorded output delta from the model. Wall-clock timing is what
/// we ultimately use to compute arrival rate and inter-chunk jitter.
struct ArrivalRecord {
    /// Wall-clock seconds since `Session.start`'s `t_session_start`.
    let t: TimeInterval
    /// Decoded PCM byte count (24kHz int16 → 2 bytes per sample).
    /// NOTE: model output is always 24 kHz regardless of provider.
    let bytes: Int
    /// Decoded int16 PCM data (24kHz mono). Stored so we can compute
    /// RMS per chunk and assemble a WAV of the model's raw output for
    /// listening / offline analysis. ~10 KB per 400 ms chunk; total
    /// ~500 KB - 1 MB per 20 s session.
    let pcm: Data
    /// Audio duration this chunk represents.
    /// Model output is always 24 kHz, so this constant is correct for both providers.
    var audioDurationSec: Double { Double(bytes) / 2.0 / 24_000.0 }

    /// Root-mean-square amplitude in `[0, 1]`. int16 normalised to ±1
    /// then RMS computed over the samples. The single most useful
    /// signal for "is the model getting quieter mid-session".
    var rms: Float {
        guard pcm.count >= 2 else { return 0 }
        let sampleCount = pcm.count / 2
        var sumSq: Double = 0
        pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self).baseAddress!
            for i in 0..<sampleCount {
                let s = Double(p[i]) / 32_767.0
                sumSq += s * s
            }
        }
        return Float((sumSq / Double(sampleCount)).squareRoot())
    }
}

/// Runs one end-to-end Realtime Translate session: streams the input
/// chunks at real-time pace, records every output delta with a precise
/// arrival timestamp, returns the collected timeline.
///
/// The production stream implementation is used directly — so any
/// behaviour we observe here (arrival cadence, burst patterns) is
/// representative of what the app sees.
struct Session {
    let apiKey: String
    let targetLang: Language
    let chunks: AudioChunkIterator
    /// Which translation provider to use. Default `.openAIRealtime`.
    let provider: TranslationModel
    /// Wire sample rate for audio sent to the stream. Must match
    /// `stream.inputWireSampleRate`: 24 kHz for OpenAI, 16 kHz for Gemini.
    let wireSampleRate: Int
    /// Wall-clock seconds between successive `send` calls. Default 0.1
    /// (100 ms) matches the production mic-capture cadence; the input
    /// chunks themselves are expected to be 100 ms each, so this gives
    /// exactly real-time pacing.
    let chunkInterval: TimeInterval

    /// Seconds to wait after the last input chunk for the model to
    /// finish emitting translation output. Empirical: model typically
    /// emits the tail of a translation 1-3 s after input ends.
    let drainTimeoutSec: TimeInterval

    struct Result {
        /// All output deltas with timestamps relative to session start.
        let arrivals: [ArrivalRecord]
        /// Wall-clock duration from session start to last delta.
        let totalElapsedSec: TimeInterval
        /// Total input audio duration we sent.
        let inputDurationSec: Double
        /// Cumulative output audio (decoded chunk sizes summed).
        var outputAudioDurationSec: Double {
            arrivals.reduce(0.0) { $0 + $1.audioDurationSec }
        }
    }

    func run() async throws -> Result {
        let clock = SystemClock()
        let stream: any TranslationStream
        switch provider {
        case .geminiLiveTranslate:
            stream = GeminiLiveTranslateStream(
                apiKey: apiKey,
                client: URLSessionWSClient(),
                clock: clock,
                speaker: .peer
            )
        case .openAIRealtime:
            stream = OpenAIRealtimeStream(
                apiKey: apiKey,
                client: URLSessionWSClient(),
                clock: clock,
                speaker: .peer
            )
        }

        print("[session] connecting to \(provider.displayName), target=\(targetLang.rawValue)…")
        try await stream.connect(target: targetLang)
        print("[session] connected; first deltas should arrive shortly")

        let t0 = Date()
        let arrivalsBox = ArrivalsBox()

        // Receive task — records every output delta with its arrival
        // time AND the decoded int16 PCM so we can analyse amplitude
        // over time and reassemble the model's raw output as a WAV.
        let outputStream = stream.output
        let receiveTask = Task {
            for await frame in outputStream {
                let t = Date().timeIntervalSince(t0)
                await arrivalsBox.append(ArrivalRecord(
                    t: t,
                    bytes: frame.pcm.count,
                    pcm: frame.pcm
                ))
            }
        }

        // Send task — streams input chunks at chunkInterval cadence.
        // Frames are already at `wireSampleRate` (AudioReader decoded to that
        // rate). We tag each frame with the wire rate so the stream (and any
        // future diagnostics) knows the sample rate of the PCM it receives.
        var sentChunks = 0
        var totalSentBytes = 0
        var lastSendTick = Date()
        for chunkBytes in chunks {
            let frame = AudioFrame(
                pcm: chunkBytes,
                sampleRate: wireSampleRate,
                channels: 1,
                format: .int16
            )
            await stream.send(frame)
            sentChunks += 1
            totalSentBytes += chunkBytes.count

            // Pace at real-time: sleep the remainder of the interval.
            // If we fell behind (heavy GC or network burst), skip the
            // sleep so we don't compound the lag.
            let now = Date()
            let elapsed = now.timeIntervalSince(lastSendTick)
            let remaining = chunkInterval - elapsed
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            lastSendTick = Date()

            if sentChunks % 50 == 0 {
                let inputSec = Double(sentChunks) * chunkInterval
                let currentArrivals = await arrivalsBox.count
                print(String(format: "[session] sent %d chunks (~%.1fs input), received %d deltas",
                             sentChunks, inputSec, currentArrivals))
            }
        }

        // int16 mono: 2 bytes per sample, divided by wire rate gives wall-clock input seconds.
        let inputDurationSec = Double(totalSentBytes) / 2.0 / Double(wireSampleRate)
        print(String(format: "[session] input streaming finished — %.1fs of audio; draining for %.1fs", inputDurationSec, drainTimeoutSec))
        try? await Task.sleep(nanoseconds: UInt64(drainTimeoutSec * 1_000_000_000))

        await stream.close()
        receiveTask.cancel()

        let arrivals = await arrivalsBox.all
        let totalElapsed = (arrivals.last?.t ?? Date().timeIntervalSince(t0))
        return Result(
            arrivals: arrivals,
            totalElapsedSec: totalElapsed,
            inputDurationSec: inputDurationSec
        )
    }
}

/// Tiny actor for thread-safe append of arrival records from the
/// receive task while the send task runs concurrently.
private actor ArrivalsBox {
    var items: [ArrivalRecord] = []
    func append(_ r: ArrivalRecord) { items.append(r) }
    var count: Int { items.count }
    var all: [ArrivalRecord] { items }
}
