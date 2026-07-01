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
}
