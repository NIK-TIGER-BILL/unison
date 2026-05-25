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
