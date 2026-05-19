import Foundation

func writeSine(sampleRate: Int, durationSec: Double, freq: Double, asInt16: Bool, path: String) {
    let count = Int(Double(sampleRate) * durationSec)
    var data = Data()
    for i in 0..<count {
        let t = Double(i) / Double(sampleRate)
        let sample = sin(2 * .pi * freq * t) * 0.5
        if asInt16 {
            let v = Int16(sample * 32_767)
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        } else {
            let v = Float(sample)
            withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
        }
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

let fixturesDir = "Tests/UnisonAudioTests/Fixtures"
try! FileManager.default.createDirectory(atPath: fixturesDir, withIntermediateDirectories: true)
writeSine(sampleRate: 48_000, durationSec: 1.0, freq: 440, asInt16: false,
          path: "\(fixturesDir)/sine-440hz-48k-f32-1sec.raw")
writeSine(sampleRate: 24_000, durationSec: 1.0, freq: 440, asInt16: true,
          path: "\(fixturesDir)/sine-440hz-24k-int16-1sec.raw")
print("Fixtures generated.")
