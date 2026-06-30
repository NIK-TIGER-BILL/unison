import Testing
@testable import UnisonAudio

@Test func streaming_upsample_totalCountRoughlyTriplesOverTime() {
    let r = StreamingResampler(srcRate: 16_000, dstRate: 48_000)!
    var total = 0
    for _ in 0..<20 { total += r.resample([Float](repeating: 0.1, count: 160)).count }
    // 20×160 @16k → ~20×480 = 9600 @48k, within the converter's startup latency.
    #expect(total >= 9600 - 400 && total <= 9600 + 50)
}

@Test func streaming_downsample_totalCountRoughlyThirdsOverTime() {
    let r = StreamingResampler(srcRate: 48_000, dstRate: 16_000)!
    var total = 0
    for _ in 0..<20 { total += r.resample([Float](repeating: 0.1, count: 480)).count }
    // 20×480 @48k → ~20×160 = 3200 @16k.
    #expect(total >= 3200 - 200 && total <= 3200 + 50)
}

@Test func streaming_emptyInput_returnsEmpty() {
    let r = StreamingResampler(srcRate: 16_000, dstRate: 48_000)!
    #expect(r.resample([]).isEmpty)
}
