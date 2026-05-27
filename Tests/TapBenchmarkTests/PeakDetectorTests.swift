import Testing
@testable import TapBenchmark

@Test func emptyBuffer_returnsNoPeaks() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    #expect(det.detectPeaks(in: []).isEmpty)
}

@Test func belowThreshold_returnsNoPeaks() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    let buf = Array(repeating: Float(0.1), count: 1000)
    #expect(det.detectPeaks(in: buf).isEmpty)
}

@Test func singlePeak_atKnownIndex() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[500] = 0.9
    #expect(det.detectPeaks(in: buf) == [500])
}

@Test func twoWellSeparatedPeaks() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 50)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[200] = 0.8
    buf[600] = 0.9
    #expect(det.detectPeaks(in: buf) == [200, 600])
}

@Test func twoClosePeaks_withinRefractory_returnsFirst() {
    // First peak at 100 (0.5), second at 130 (0.9), refractory=50.
    // We detect the onset (first sample over threshold), not the loudest
    // sample — click latency is measured at the leading edge.
    let det = PeakDetector(threshold: 0.3, refractorySamples: 50)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[100] = 0.5
    buf[130] = 0.9
    #expect(det.detectPeaks(in: buf) == [100])
}

@Test func negativeAmplitude_alsoCountsAsPeak() {
    let det = PeakDetector(threshold: 0.3, refractorySamples: 100)
    var buf = Array(repeating: Float(0.0), count: 1000)
    buf[400] = -0.8
    #expect(det.detectPeaks(in: buf) == [400])
}
