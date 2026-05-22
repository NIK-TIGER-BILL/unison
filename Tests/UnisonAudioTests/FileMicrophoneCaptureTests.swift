import Testing
@testable import UnisonAudio
@testable import UnisonDomain

@Test func fileMicrophone_loadAsInt16Mono24k_returnsExpectedPCMSize() throws {
    let url = writeTinyWav(seconds: 1.0)
    defer { deleteFixture(url) }
    let pcm = try FileMicrophoneCapture.loadAsInt16Mono24k(url: url)
    // 1 s at 24 kHz × 2 bytes/sample × 1 ch = 48000 bytes (± rounding).
    #expect(abs(pcm.count - 48_000) < 200, "got \(pcm.count) bytes")
}

@Test func fileMicrophone_emitsFramesWithCorrectShape() async throws {
    let url = writeTinyWav(seconds: 0.5)
    defer { deleteFixture(url) }

    let mic = FileMicrophoneCapture(fileURL: url, loop: false)
    let stream = mic.start(deviceUID: nil)

    var frames: [AudioFrame] = []
    // Collect ~6 frames or until stream ends. With `loop=false` and a
    // 0.5 s payload at 100 ms/frame the stream should finish after ~5
    // frames; collecting 10 max is a safety upper bound.
    let collector = Task { () -> [AudioFrame] in
        for await f in stream {
            frames.append(f)
            if frames.count >= 10 { break }
        }
        return frames
    }
    let collected = await collector.value
    mic.stop()

    #expect(!collected.isEmpty)
    for f in collected {
        #expect(f.sampleRate == 24_000)
        #expect(f.channels == 1)
        #expect(f.format == .int16)
    }
    // Last (partial) frame may be shorter; the typical frame is exactly
    // `samplesPerFrame * 2` bytes (4800).
    if collected.count >= 2 {
        #expect(collected[0].pcm.count == FileMicrophoneCapture.samplesPerFrame * 2)
    }
}

@Test func fileMicrophone_loopsWhenLoopFlagIsTrue() async throws {
    // 0.2 s payload @ 100 ms/frame → ~2 frames per pass. With loop=true,
    // collecting 5 frames must come from at least two passes (the second
    // pass wraps back to the start of the file).
    let url = writeTinyWav(seconds: 0.2)
    defer { deleteFixture(url) }

    let mic = FileMicrophoneCapture(fileURL: url, loop: true)
    let stream = mic.start(deviceUID: nil)

    var frames: [AudioFrame] = []
    let collector = Task { () -> [AudioFrame] in
        for await f in stream {
            frames.append(f)
            if frames.count >= 5 { break }
        }
        return frames
    }
    let collected = await collector.value
    mic.stop()

    #expect(collected.count == 5, "looping should produce > one file's worth of frames; got \(collected.count)")
}

@Test func fileMicrophone_missingFileEmitsEmptyStream() async throws {
    let mic = FileMicrophoneCapture(fileURL: makeBogusWavURL(), loop: false)
    let stream = mic.start(deviceUID: nil)

    var count = 0
    for await _ in stream { count += 1; if count > 5 { break } }
    mic.stop()
    #expect(count == 0, "missing file should not crash and should yield no frames")
}
