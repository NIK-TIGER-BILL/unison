import Foundation
import AVFoundation
import Testing
@testable import UnisonAudio

// Deterministic proof that the seam declick (`AVAudioOutputMixer.declickSeam`)
// removes chunk-boundary clicks — the "щелчки на стыках" the user reported.
// A click IS a large sample-to-sample step at a buffer boundary; the declick
// ramps the first ~2 ms of each buffer from where audio left off so the step
// is spread across 96 samples instead of happening in one. These tests measure
// the seam step WITH vs WITHOUT the ramp, with no engine and no live timing —
// so they run in CI and in the VM without a human listening.
//
// Complements the live full-chain integration run (`pacing-eval
// --full-chain-render`, A/B via `UNISON_DISABLE_DECLICK`), which showed the
// declick halves the worst sample-step (0.50→0.28) on real Gemini output.
@Suite struct DeclickTests {
    static let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 48_000, channels: 1, interleaved: false)!

    static func buffer(_ s: [Float]) -> AVAudioPCMBuffer {
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
        b.frameLength = AVAudioFrameCount(s.count)
        for i in s.indices { b.floatChannelData![0][i] = s[i] }
        return b
    }

    static func samples(_ b: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
    }

    /// Largest sample-to-sample step across the seam: from `prevEnd` into the
    /// first samples of `b`. This is the click magnitude — what the ear hears.
    static func seamMaxStep(prevEnd: Float, _ b: AVAudioPCMBuffer) -> Float {
        let s = Self.samples(b)
        var m = abs(s[0] - prevEnd)
        for i in 1..<min(s.count, 200) { m = max(m, abs(s[i] - s[i - 1])) }
        return m
    }

    @Test func declick_resumeFromSilence_smoothsOnsetStep() {
        // Buffer resuming after the player emitted digital silence (prevEnd 0):
        // a steady 0.6 tone. Raw, the very first sample steps 0 → 0.6 — the loud
        // resume click. The declick (from 0) must spread it over the 2 ms ramp.
        let raw = [Float](repeating: 0.6, count: 480)
        let stepNo = Self.seamMaxStep(prevEnd: 0, Self.buffer(raw))
        let bufYes = Self.buffer(raw)
        AVAudioOutputMixer.declickSeam(bufYes, from: 0)
        let stepYes = Self.seamMaxStep(prevEnd: 0, bufYes)

        #expect(stepNo >= 0.59)                       // raw: a 0.6 click
        #expect(stepYes < 0.02)                       // 0.6 over 96 samples ≈ 0.006/step
        #expect(Self.samples(bufYes)[0] == 0)         // ramp begins from silence
        #expect(stepYes < stepNo / 10)                // ≥10× smaller
    }

    @Test func declick_continuousBoundaryStep_smoothsAgcOrResamplerJump() {
        // Consecutive chunks whose AGC gain / resampler-reset differ: prev ends
        // at +0.5, next starts at −0.4 → a 0.9 step at the seam. The declick
        // (from 0.5) continues from the previous sample and glides in.
        let raw = [Float](repeating: -0.4, count: 480)
        let stepNo = Self.seamMaxStep(prevEnd: 0.5, Self.buffer(raw))
        let bufYes = Self.buffer(raw)
        AVAudioOutputMixer.declickSeam(bufYes, from: 0.5)
        let stepYes = Self.seamMaxStep(prevEnd: 0.5, bufYes)

        #expect(stepNo >= 0.89)                       // raw: a 0.9 click
        #expect(stepYes < 0.03)
        #expect(abs(Self.samples(bufYes)[0] - 0.5) < 1e-6)  // continues from prev end
        #expect(stepYes < stepNo / 10)
    }

    @Test func declick_alreadyContinuous_introducesNoNotch() {
        // No step at the seam (prevEnd == the buffer's level): the ramp must be
        // a no-op — it must NOT carve a notch (the over-fire bug we fixed).
        let raw = [Float](repeating: 0.3, count: 480)
        let bufYes = Self.buffer(raw)
        AVAudioOutputMixer.declickSeam(bufYes, from: 0.3)
        #expect(Self.samples(bufYes).allSatisfy { abs($0 - 0.3) < 1e-6 })
        #expect(Self.seamMaxStep(prevEnd: 0.3, bufYes) < 1e-6)
    }

    @Test func declick_rampLength_isTwoMilliseconds() {
        // The ramp touches only the first ~2 ms (96 samples @ 48k); sample 96
        // onward is the untouched signal. Guards against a regression that
        // widens the ramp into an audible fade.
        let raw = [Float](repeating: 1.0, count: 480)
        let buf = Self.buffer(raw)
        AVAudioOutputMixer.declickSeam(buf, from: 0)
        let s = Self.samples(buf)
        #expect(s[0] == 0)                            // ramp start
        #expect(s[95] < 1.0)                          // still ramping just before the end
        #expect(s[96] == 1.0)                         // back on the signal at 96
        #expect(s[200] == 1.0)
    }

    // MARK: - resume-from-silence detection (which `start` to hand declickSeam)
    //
    // declickSeam is correct GIVEN the right `start`; the surviving click was in
    // DECIDING it. `scheduledBufferCount <= playedBackBufferCount` rode the
    // `.dataPlayedBack` completion lag (the HAL/Bluetooth output latency), so a
    // brief gap read "not dry" and a post-silence buffer got ramped from a stale
    // non-zero prevSample → the 0→prevSample click. `seamResumeDecision` replaces
    // that with a wall-clock queue-end model: no completion lag, and no false
    // positive on cushion-absorbed jitter (why the raw schedGap test was wrong).

    @Test func seamResume_firstBufferOrReset_isResumeFromSilence() {
        // Fresh queue (queueEndsAt reset to 0): the first buffer resumes from
        // silence → ramp from 0; the queue clock starts at `now`.
        let (resuming, end) = AVAudioOutputMixer.seamResumeDecision(
            now: 1000, queueEndsAt: 0, bufferDurationSec: 0.25)
        #expect(resuming == true)
        #expect(abs(end - 1000.25) < 1e-9)
    }

    @Test func seamResume_absorbedJitter_isNotResume_noFalsePositive() {
        // A chunk lands late but the cushion still holds ~0.65s (queue ends at
        // 1000.75, now 1000.10) — NOT an underrun. Must NOT ramp from 0 (that was
        // the schedGap false-positive that notched healthy seams); it appends to
        // the existing queue.
        let (resuming, end) = AVAudioOutputMixer.seamResumeDecision(
            now: 1000.10, queueEndsAt: 1000.75, bufferDurationSec: 0.25)
        #expect(resuming == false)
        #expect(abs(end - 1001.0) < 1e-9)
    }

    @Test func seamResume_realGap_detectedImmediately() {
        // The queue drained 0.25s ago (ends at 1000.75, now 1001.0) → the player
        // is on silence → resume from 0. The wall-clock model catches this AT the
        // gap (the `.dataPlayedBack` count would still read "not dry" here, the
        // bug), and restarts the clock at `now`.
        let (resuming, end) = AVAudioOutputMixer.seamResumeDecision(
            now: 1001.0, queueEndsAt: 1000.75, bufferDurationSec: 0.25)
        #expect(resuming == true)
        #expect(abs(end - 1001.25) < 1e-9)
    }

    @Test func seamResume_exactlyAtQueueEnd_countsAsResume() {
        // Boundary: now == queueEndsAt. The queued audio has just finished, so
        // treat it as drained (`>=`) — ramp from 0, not from a sample no longer
        // playing.
        let (resuming, _) = AVAudioOutputMixer.seamResumeDecision(
            now: 1000.75, queueEndsAt: 1000.75, bufferDurationSec: 0.25)
        #expect(resuming == true)
    }
}
