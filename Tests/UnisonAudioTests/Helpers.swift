import Foundation
@testable import UnisonAudio
@testable import UnisonDomain

// Helpers in this file deliberately avoid `import Testing` so the
// `_Testing_Foundation` cross-import overlay (missing from the
// Command Line Tools `Testing.framework` install) is not triggered
// when test files only import `Testing`.

func fixture(_ name: String) -> Data {
    let url = Bundle.module.url(forResource: name, withExtension: "raw", subdirectory: "Fixtures")!
    return try! Data(contentsOf: url)
}

func makeFrame(pcm: Data, rate: Int, channels: Int = 1, format: AudioSampleFormat) -> AudioFrame {
    AudioFrame(pcm: pcm, sampleRate: rate, channels: channels, format: format)
}

func dataOfCount(_ count: Int) -> Data {
    Data(count: count)
}

/// Thread-safe frame sink a collector task and a test can both observe —
/// lets tests assert mid-stream state ("nothing emitted yet") instead of
/// only the final result. Lives here because test files avoid importing
/// Foundation directly (see the note at the top of this file).
final class FrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AudioFrame] = []
    func append(_ f: AudioFrame) { lock.lock(); frames.append(f); lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return frames.count }
}
