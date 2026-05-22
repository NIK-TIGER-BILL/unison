import Foundation
@testable import UnisonAudio

// Helpers for `FileMicrophoneCaptureTests`. Lives in a file that does
// NOT `import Testing` so the missing `_Testing_Foundation` cross-import
// overlay (Command Line Tools-only setups) is not triggered.

/// Build a tiny in-memory WAV file (PCM int16 mono @ 24 kHz) on disk
/// and return its URL. Avoids depending on a fixture file shipped under
/// `resources:` — keeps tests self-contained.
func writeTinyWav(seconds: Double = 0.5) -> URL {
    let sampleRate: Int = 24_000
    let frames = Int(Double(sampleRate) * seconds)
    var samples = Data()
    for i in 0..<frames {
        let t = Double(i) / Double(sampleRate)
        let s = Int16(sin(2 * .pi * 440 * t) * 0.5 * 32_767)
        var le = s.littleEndian
        withUnsafeBytes(of: &le) { samples.append(contentsOf: $0) }
    }

    let payloadBytes = samples.count
    let byteRate: UInt32 = UInt32(sampleRate * 2)
    let blockAlign: UInt16 = 2

    var wav = Data()
    func a32<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) }
    }
    func a16<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        withUnsafeBytes(of: &x) { wav.append(contentsOf: $0) }
    }
    wav.append("RIFF".data(using: .ascii)!)
    a32(UInt32(36 + payloadBytes))
    wav.append("WAVE".data(using: .ascii)!)
    wav.append("fmt ".data(using: .ascii)!)
    a32(UInt32(16))
    a16(UInt16(1))
    a16(UInt16(1))
    a32(UInt32(sampleRate))
    a32(byteRate)
    a16(blockAlign)
    a16(UInt16(16))
    wav.append("data".data(using: .ascii)!)
    a32(UInt32(payloadBytes))
    wav.append(samples)

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FileMicTests-\(UUID().uuidString).wav")
    try! wav.write(to: url)
    return url
}

/// Delete a fixture URL safely (silent failure for missing files).
func deleteFixture(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Wrapper that resolves a bogus path string into a `URL` without
/// `Foundation` in the test file.
func makeBogusWavURL() -> URL {
    URL(fileURLWithPath: "/tmp/this-file-should-not-exist-\(UUID().uuidString).wav")
}
