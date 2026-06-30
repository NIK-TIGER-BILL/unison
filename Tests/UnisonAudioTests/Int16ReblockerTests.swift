import Testing
@testable import UnisonAudio

@Test func reblocker_emitsFullBlocks_andCarriesRemainder() {
    var rb = Int16Reblocker(blockSize: 480)
    let first = rb.push([Int16](repeating: 1, count: 600))
    #expect(first.count == 1)          // 600 → one 480 block
    #expect(first[0].count == 480)
    #expect(rb.pending == 120)         // 120 carried
    let second = rb.push([Int16](repeating: 2, count: 600))
    #expect(second.count == 1)         // 120 + 600 = 720 → one 480 block
    #expect(rb.pending == 240)
}

@Test func reblocker_smallPushes_accumulateUntilBlock() {
    var rb = Int16Reblocker(blockSize: 4)
    #expect(rb.push([1, 2]).isEmpty)
    #expect(rb.push([3]).isEmpty)
    let blocks = rb.push([4, 5])
    #expect(blocks == [[1, 2, 3, 4]])
    #expect(rb.pending == 1)
}

@Test func reblocker_noSampleLoss_acrossManyPushes() {
    var rb = Int16Reblocker(blockSize: 100)
    var emitted = 0
    for chunk in [37, 200, 1, 99, 63] {
        emitted += rb.push([Int16](repeating: 0, count: chunk)).count * 100
    }
    #expect(emitted + rb.pending == 37 + 200 + 1 + 99 + 63)
}

@Test func reblocker_reset_dropsCarry() {
    var rb = Int16Reblocker(blockSize: 4)
    _ = rb.push([1, 2, 3])
    rb.reset()
    #expect(rb.pending == 0)
}
