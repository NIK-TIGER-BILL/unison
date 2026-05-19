import Testing
@testable import UnisonAudio
@testable import UnisonDomain

@Test func batcher_emitsFullChunksOnly() async {
    let batcher = AudioBatcher(targetChunkMs: 100, sampleRate: 24_000, channels: 1, format: .int16)
    let halfChunk = makeFrame(pcm: dataOfCount(2400), rate: 24_000, format: .int16)

    // Drive the AsyncStream from a Task that returns the collected frames so
    // mutable state never crosses an isolation boundary (Swift 6 strict
    // concurrency).
    let collector = Task { () -> [AudioFrame] in
        var collected: [AudioFrame] = []
        for await out in batcher.output {
            collected.append(out)
            if collected.count == 1 { break }
        }
        return collected
    }

    batcher.feed(halfChunk)
    try? await Task.sleep(nanoseconds: 30_000_000)
    // Half a chunk should not yet emit anything.
    #expect(!collector.isCancelled)

    batcher.feed(halfChunk)
    let collected = await collector.value
    #expect(collected.count == 1)
    #expect(collected[0].pcm.count == 4800)
}

@Test func batcher_splitsLargeFrame() async {
    let batcher = AudioBatcher(targetChunkMs: 100, sampleRate: 24_000, channels: 1, format: .int16)
    let big = makeFrame(pcm: dataOfCount(12_000), rate: 24_000, format: .int16)

    let collector = Task { () -> [AudioFrame] in
        var collected: [AudioFrame] = []
        for await out in batcher.output {
            collected.append(out)
            if collected.count == 2 { break }
        }
        return collected
    }
    batcher.feed(big)
    let collected = await collector.value
    #expect(collected.count == 2)
    #expect(collected.allSatisfy { $0.pcm.count == 4800 })
}
