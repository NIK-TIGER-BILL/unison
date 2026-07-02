import Foundation
import AVFoundation
import UnisonAudio
import UnisonDomain

/// Drives model-output audio through the **real production `AVAudioOutputMixer`**
/// — the exact same object the app uses, with its real per-chunk AGC, seam
/// declick, `AVAudioUnitTimePitch`, and `scheduleBuffer` path — and captures the
/// post-chain signal via `UNISON_DUMP_PLAYBACK_WAV`. Unlike `PlaybackOfflineRender`
/// (which rebuilds a bare `player → timePitch → mixer` graph and so exercises
/// NONE of our DSP), this reproduces the actual chunk SEAMS where clicks live.
///
/// Purpose: verify — autonomously, no human listening — that the shipped seam
/// declick actually removes chunk-boundary clicks. Re-chunks the assembled
/// model output at `chunkMs`, resamples each chunk independently through the
/// production `Resampler.fromWire` (per-chunk reset = the real seam scenario),
/// and feeds them to `playTranslated` at real-time cadence so the pacing
/// controller sits at rate 1.0 (shallow queue) exactly like a healthy session.
///
/// A/B the declick with `UNISON_DISABLE_DECLICK=1` (skips the ramp) vs unset:
/// the click floor (sample-step discontinuities) should be near-zero WITH the
/// ramp and spike at ~`chunkMs` intervals WITHOUT it — proof the ramp is what
/// removes the seams.
struct FullChainRender {
    /// Assembled model output as 24 kHz int16 mono (the wire format both
    /// providers emit; also what `pacing-eval` writes as `*-model-output.wav`).
    let pcm24kInt16: Data
    let outputDir: URL
    let label: String
    /// Chunk size fed per `scheduleBuffer`, ms. ~250 matches the measured
    /// median model delta size (see arrival p50 in the pacing report).
    let chunkMs: Int

    func run() async throws -> URL {
        let dumpURL = outputDir.appendingPathComponent("\(label)-fullchain-dump.wav")
        // Must be set BEFORE `start(_:)` — the dump tap is armed there.
        setenv("UNISON_DUMP_PLAYBACK_WAV", dumpURL.path, 1)
        defer { unsetenv("UNISON_DUMP_PLAYBACK_WAV") }

        let mixer = AVAudioOutputMixer()
        try await mixer.start(deviceUID: nil)
        mixer.muteFinalOutputForCapture()   // capture without blasting audio

        var cont: AsyncStream<AudioFrame>.Continuation!
        let stream = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(64)) { cont = $0 }
        let playTask = Task { await mixer.playTranslated(stream) }

        let bytesPerChunk = 2 * 24_000 * chunkMs / 1000   // int16 @ 24 kHz
        var off = 0, chunks = 0
        while off < pcm24kInt16.count {
            let end = min(off + bytesPerChunk, pcm24kInt16.count)
            let wireChunk = pcm24kInt16.subdata(in: off..<end)
            let wireFrame = AudioFrame(pcm: wireChunk, sampleRate: 24_000, channels: 1, format: .int16)
            // EXACT production conversion: 24k int16 wire → 48k f32 player frame.
            cont.yield(Resampler.fromWire(wireFrame, targetSampleRate: 48_000))
            off = end
            chunks += 1
            // Real-time cadence so the pacing controller holds rate 1.0 (shallow
            // queue), reproducing a healthy session — not a burst drain.
            try await Task.sleep(nanoseconds: UInt64(chunkMs) * 1_000_000)
        }
        cont.finish()
        _ = await playTask.value
        // Let the last queued buffers (~one deadband of cushion) play out and be
        // captured, plus a final pacing tick, before closing the dump.
        try await Task.sleep(nanoseconds: 900_000_000)
        mixer.stop()

        let declick = ProcessInfo.processInfo.environment["UNISON_DISABLE_DECLICK"] == "1" ? "OFF" : "ON"
        print("[full-chain] fed \(chunks) chunks of \(chunkMs)ms through the real "
              + "AVAudioOutputMixer (declick=\(declick)); dump → \(dumpURL.lastPathComponent)")
        return dumpURL
    }
}
