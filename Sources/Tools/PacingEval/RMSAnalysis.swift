import Foundation

/// Analyses model-output amplitude over time. The goal is to answer
/// the question "is the audio fading as the session progresses?"
/// — i.e. does the model itself emit progressively quieter audio,
/// or is the fade introduced downstream on our side?
struct RMSAnalysis {
    /// One time-binned RMS measurement.
    struct Bin {
        let startSec: Double
        let endSec: Double
        let rmsMean: Float
        let rmsMax: Float
        let chunkCount: Int
    }

    let perChunkRMS: [(t: Double, rms: Float)]
    /// 1-second bins of RMS — easier to spot trends than per-chunk noise.
    let bins: [Bin]
    /// Simple linear regression slope of bin-RMS over time (RMS units
    /// per second). Negative ⇒ getting quieter; near zero ⇒ stable.
    let slopePerSec: Double
    /// Intercept of the linear fit at t=0 (= "initial RMS").
    let intercept: Double
    /// First and last bin means — quick visual ratio.
    var firstBinMean: Float { bins.first?.rmsMean ?? 0 }
    var lastBinMean: Float { bins.last?.rmsMean ?? 0 }
    var ratioLastToFirst: Float {
        guard firstBinMean > 0 else { return 0 }
        return lastBinMean / firstBinMean
    }

    static func compute(arrivals: [ArrivalRecord], binSec: Double = 1.0) -> RMSAnalysis {
        let chunks = arrivals.map { ($0.t, $0.rms) }
        // Time-bin by 1s buckets.
        let maxT = chunks.last?.0 ?? 0
        let binCount = Int(ceil(maxT / binSec)) + 1
        var binSum = [Double](repeating: 0, count: binCount)
        var binMax = [Float](repeating: 0, count: binCount)
        var binCt  = [Int](repeating: 0, count: binCount)
        for (t, r) in chunks {
            let i = max(0, min(binCount - 1, Int(t / binSec)))
            binSum[i] += Double(r)
            binMax[i] = max(binMax[i], r)
            binCt[i]  += 1
        }
        var bins: [Bin] = []
        for i in 0..<binCount where binCt[i] > 0 {
            bins.append(Bin(
                startSec: Double(i) * binSec,
                endSec:   Double(i + 1) * binSec,
                rmsMean:  Float(binSum[i] / Double(binCt[i])),
                rmsMax:   binMax[i],
                chunkCount: binCt[i]
            ))
        }

        // Linear regression on (bin_mid_t, bin_rms_mean).
        // Use only non-empty bins where chunk count >= 1. Excludes
        // long silence runs from biasing the trend toward "fading".
        let xs = bins.map { ($0.startSec + $0.endSec) / 2 }
        let ys = bins.map { Double($0.rmsMean) }
        let (slope, intercept) = linearRegression(xs: xs, ys: ys)
        return RMSAnalysis(
            perChunkRMS: chunks.map { ($0.0, $0.1) },
            bins: bins,
            slopePerSec: slope,
            intercept: intercept
        )
    }

    private static func linearRegression(xs: [Double], ys: [Double]) -> (slope: Double, intercept: Double) {
        guard xs.count >= 2, xs.count == ys.count else { return (0, 0) }
        let n = Double(xs.count)
        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n
        var num: Double = 0
        var den: Double = 0
        for i in 0..<xs.count {
            let dx = xs[i] - meanX
            num += dx * (ys[i] - meanY)
            den += dx * dx
        }
        guard den > 0 else { return (0, meanY) }
        let slope = num / den
        let intercept = meanY - slope * meanX
        return (slope, intercept)
    }
}

/// Minimal int16 mono WAV writer for the assembled model output. Lets
/// us listen to what the API actually emitted, independent of our
/// playback pipeline.
struct WAVWriter {
    static func writeInt16Mono(pcm: Data, sampleRate: UInt32, to url: URL) throws {
        var data = Data()
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcm.count)
        let fileSize = dataSize &+ 36

        data.append(contentsOf: "RIFF".utf8)
        data.append(uint32LE(fileSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(uint32LE(16))                // fmt chunk size
        data.append(uint16LE(1))                 // PCM = 1
        data.append(uint16LE(channels))
        data.append(uint32LE(sampleRate))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append(contentsOf: "data".utf8)
        data.append(uint32LE(dataSize))
        data.append(pcm)

        try data.write(to: url)
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }
}
