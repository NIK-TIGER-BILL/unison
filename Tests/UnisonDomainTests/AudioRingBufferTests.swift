import Foundation
import Testing
@testable import UnisonDomain

private func frame(_ id: UInt8) -> AudioFrame {
    AudioFrame(pcm: Data([id, id, id, id]), sampleRate: 24_000, channels: 1, format: .int16)
}

@Test func ringBuffer_appendUnderCapacity_returnsAllInOrder() {
    let buf = AudioRingBuffer(maxFrames: 4)
    buf.append(frame(1))
    buf.append(frame(2))
    buf.append(frame(3))
    let drained = buf.drain()
    #expect(drained.map { $0.pcm[0] } == [1, 2, 3])
}

@Test func ringBuffer_appendOverCapacity_dropsOldest() {
    let buf = AudioRingBuffer(maxFrames: 3)
    buf.append(frame(1))
    buf.append(frame(2))
    buf.append(frame(3))
    buf.append(frame(4))  // pushes 1 out
    buf.append(frame(5))  // pushes 2 out
    #expect(buf.drain().map { $0.pcm[0] } == [3, 4, 5])
}

@Test func ringBuffer_drainEmptiesBuffer() {
    let buf = AudioRingBuffer(maxFrames: 4)
    buf.append(frame(1))
    _ = buf.drain()
    #expect(buf.drain().isEmpty)
}

@Test func ringBuffer_clearEmpties() {
    let buf = AudioRingBuffer(maxFrames: 4)
    buf.append(frame(1))
    buf.append(frame(2))
    buf.clear()
    #expect(buf.drain().isEmpty)
}
