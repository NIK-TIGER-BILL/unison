import Foundation
import Testing
@testable import UnisonDomain

// WireFrameBatcher — coalesces tiny wire-format frames into ~100 ms sends.
// Capture delivers HAL-IO-cycle frames (~10 ms): unbatched, every one became
// its own JSON+base64 WebSocket message (~100 messages/s per stream — the
// cookbook recommends 50–100 ms chunks), and the reconnect ring buffer
// (30 frames, sized as "3 s at ~100 ms frames") actually held only ~0.3 s.
// Batching restores both: ~10 messages/s and a real 3 s replay window.

private func wireFrame(ms: Int, rate: Int = 16_000, fill: UInt8 = 0x11) -> AudioFrame {
    let samples = rate * ms / 1000
    return AudioFrame(pcm: Data(repeating: fill, count: samples * 2),
                      sampleRate: rate, channels: 1, format: .int16)
}

@Test func batcher_accumulatesUntilTarget() {
    var b = WireFrameBatcher(targetDurationMs: 100)
    #expect(b.add(wireFrame(ms: 40)) == nil)
    #expect(b.add(wireFrame(ms: 40)) == nil)
    let batch = b.add(wireFrame(ms: 40))
    #expect(batch != nil)
    #expect(batch?.durationMs == 120)
    #expect(batch?.sampleRate == 16_000)
    #expect(batch?.format == .int16)
    // The emitted batch must be the three payloads concatenated in order.
    let expectedBytes: Int = 3 * 640 * 2  // 3 × (16000 × 0.04) samples × 2 B
    #expect(batch?.pcm.count == expectedBytes)
}

@Test func batcher_singleLargeFrame_passesStraightThrough() {
    var b = WireFrameBatcher(targetDurationMs: 100)
    let batch = b.add(wireFrame(ms: 250))
    #expect(batch?.durationMs == 250)
}

@Test func batcher_flush_returnsRemainderThenEmpty() {
    var b = WireFrameBatcher(targetDurationMs: 100)
    #expect(b.add(wireFrame(ms: 30)) == nil)
    let rest = b.flush()
    #expect(rest?.durationMs == 30)
    #expect(b.flush() == nil)
}

@Test func batcher_emptyFrames_areDropped() {
    var b = WireFrameBatcher(targetDurationMs: 100)
    let empty = AudioFrame(pcm: Data(), sampleRate: 16_000, channels: 1, format: .int16)
    #expect(b.add(empty) == nil)
    #expect(b.flush() == nil)
}

@Test func batcher_formatChange_emitsPendingImmediately() {
    // Wire format is uniform per stream in practice; if it ever changes
    // mid-stream (engine switch), the pending batch is emitted as-is rather
    // than concatenating incompatible payloads.
    var b = WireFrameBatcher(targetDurationMs: 100)
    #expect(b.add(wireFrame(ms: 40, rate: 16_000)) == nil)
    let flushed = b.add(wireFrame(ms: 40, rate: 24_000))
    #expect(flushed?.sampleRate == 16_000)
    #expect(flushed?.durationMs == 40)
    // The incompatible frame became the new pending batch.
    let rest = b.flush()
    #expect(rest?.sampleRate == 24_000)
    #expect(rest?.durationMs == 40)
}

@Test func batcher_ordersPayloadBytes() {
    var b = WireFrameBatcher(targetDurationMs: 50)
    _ = b.add(wireFrame(ms: 30, fill: 0xAA))
    let batch = b.add(wireFrame(ms: 30, fill: 0xBB))
    #expect(batch != nil)
    if let pcm = batch?.pcm {
        let first = 16_000 * 30 / 1000 * 2
        #expect(pcm.prefix(first).allSatisfy { $0 == 0xAA })
        #expect(pcm.suffix(pcm.count - first).allSatisfy { $0 == 0xBB })
    }
}
