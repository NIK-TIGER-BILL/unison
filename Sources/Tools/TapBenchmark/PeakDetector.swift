import Foundation

public struct PeakDetector {
    public let threshold: Float
    public let refractorySamples: Int

    public init(threshold: Float, refractorySamples: Int) {
        self.threshold = threshold
        self.refractorySamples = refractorySamples
    }

    public func detectPeaks(in buffer: [Float]) -> [Int] {
        guard !buffer.isEmpty else { return [] }
        var peaks: [Int] = []
        var i = 0
        while i < buffer.count {
            if abs(buffer[i]) >= threshold {
                peaks.append(i)
                i = i + refractorySamples
            } else {
                i += 1
            }
        }
        return peaks
    }
}
