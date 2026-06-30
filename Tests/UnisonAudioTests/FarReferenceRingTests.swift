import Testing
@testable import UnisonAudio

private func write(_ ring: FarReferenceRing, _ samples: [Int16]) -> Int {
    samples.withUnsafeBufferPointer { ring.write($0) }
}

private func read(_ ring: FarReferenceRing, _ count: Int) -> [Int16] {
    var out = [Int16](repeating: -1, count: count)
    let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0) }
    return Array(out[0..<n])
}

@Test func ring_writeThenRead_returnsSameSamples() {
    let ring = FarReferenceRing(capacity: 8)
    #expect(write(ring, [1, 2, 3]) == 3)
    #expect(read(ring, 3) == [1, 2, 3])
}

@Test func ring_readMoreThanAvailable_returnsOnlyAvailable() {
    let ring = FarReferenceRing(capacity: 8)
    _ = write(ring, [5, 6])
    #expect(read(ring, 4) == [5, 6])   // underrun → caller zero-fills the rest
}

@Test func ring_overflow_dropsExcessAndReportsShortWrite() {
    let ring = FarReferenceRing(capacity: 4)   // holds 4 samples max
    let wrote = write(ring, [1, 2, 3, 4, 5, 6])
    #expect(wrote == 4)                 // newest 2 dropped
    #expect(read(ring, 4) == [1, 2, 3, 4])
}

@Test func ring_wrapsAround() {
    let ring = FarReferenceRing(capacity: 4)
    _ = write(ring, [1, 2, 3])
    #expect(read(ring, 2) == [1, 2])    // head advances
    _ = write(ring, [4, 5, 6])          // wraps past the physical end
    #expect(read(ring, 4) == [3, 4, 5, 6])
}

@Test func ring_clear_emptiesBuffer() {
    let ring = FarReferenceRing(capacity: 8)
    _ = write(ring, [1, 2, 3])
    ring.clear()
    #expect(read(ring, 3) == [])
}

@Test func ring_roundsCapacityUpToPowerOfTwo() {
    // capacity 5 → rounded to 8: eight samples fit, the ninth is dropped.
    let ring = FarReferenceRing(capacity: 5)
    #expect(write(ring, [1, 2, 3, 4, 5, 6, 7, 8]) == 8)
    #expect(write(ring, [9]) == 0)
}
