import Foundation
import Testing
@testable import UnisonAudio

// `[sched-stall]` threshold. The old fixed 250 ms fired on nearly every
// normal chunk: the model ships 250–400 ms chunks at real-time rate, so the
// natural inter-schedule gap ≈ the chunk duration — a 2026-07-02 field log
// had 145 false "stall" lines (gaps 250–380 ms, frame=250 ms) drowning the
// one real 792 ms event. A gap is only a stall when it exceeds the previous
// chunk's duration (the expected cadence) plus jitter margin.

@Test func schedStall_normalCadence_isNotAStall() {
    // 250 ms chunks arriving every 250–380 ms = healthy real-time delivery.
    #expect(!AVAudioOutputMixer.isSchedStall(gapMs: 250, prevChunkDurMs: 250))
    #expect(!AVAudioOutputMixer.isSchedStall(gapMs: 380, prevChunkDurMs: 250))
    // 400 ms chunks arriving every ~400–540 ms — same story at OpenAI sizes.
    #expect(!AVAudioOutputMixer.isSchedStall(gapMs: 540, prevChunkDurMs: 400))
}

@Test func schedStall_gapWellPastCadence_isAStall() {
    // The real event from the field log: 792 ms gap on 250 ms chunks.
    #expect(AVAudioOutputMixer.isSchedStall(gapMs: 792, prevChunkDurMs: 250))
    // And a burst-then-silence on 400 ms chunks.
    #expect(AVAudioOutputMixer.isSchedStall(gapMs: 700, prevChunkDurMs: 400))
}

@Test func schedStall_tinyChunks_floorPreventsNoise() {
    // Tiny chunks (e.g. a 40 ms tail) must not make the threshold hair-
    // trigger: the 400 ms floor keeps sub-cadence jitter quiet.
    #expect(!AVAudioOutputMixer.isSchedStall(gapMs: 350, prevChunkDurMs: 40))
    #expect(AVAudioOutputMixer.isSchedStall(gapMs: 450, prevChunkDurMs: 40))
}

@Test func schedStall_firstChunk_neverStalls() {
    // No previous chunk (gap 0 / unknown cadence) — never flag.
    #expect(!AVAudioOutputMixer.isSchedStall(gapMs: 0, prevChunkDurMs: 0))
}
