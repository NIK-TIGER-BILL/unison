import Testing
@testable import UnisonDomain

/// Wait briefly for the I/O queue to flush. The store dispatches writes
/// async; a short sleep is sufficient since the queue is `userInitiated`.
private func waitForFlush() async {
    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
}

@Test func fileLogStore_writesLineToDisk() async throws {
    let store = makeTempStore()
    store.write(category: "TestCat", level: "info", message: "hello world")
    await waitForFlush()

    let contents = store.readAll()
    #expect(contents.contains("[TestCat:info]"))
    #expect(contents.contains("hello world"))
}

@Test func fileLogStore_emitsBannerOnFirstWrite() async throws {
    let store = makeTempStore()
    store.write(category: "TestCat", level: "info", message: "first line")
    await waitForFlush()

    let contents = store.readAll()
    // The banner is the first line and helps the integration test
    // confirm it grabbed a fresh log file (not a stale SCP'd one).
    #expect(contents.contains("Unison log file opened"))
}

@Test func fileLogStore_appendsMultipleLines() async throws {
    let store = makeTempStore()
    for i in 0..<5 {
        store.write(category: "C", level: "info", message: "line-\(i)")
    }
    await waitForFlush()

    let contents = store.readAll()
    for i in 0..<5 {
        #expect(contents.contains("line-\(i)"))
    }
}

@Test func fileLogStore_rotatesWhenFileExceedsMax() async throws {
    // 200-byte cap forces rotation almost immediately. Each line is
    // ~80 bytes so two lines push us past.
    let store = makeTempStore(maxFileBytes: 200, maxFiles: 3)
    store.write(category: "Cat", level: "info", message: repeated("x", 80))
    await waitForFlush()
    store.write(category: "Cat", level: "info", message: repeated("y", 80))
    await waitForFlush()
    store.write(category: "Cat", level: "info", message: "after-rotate")
    await waitForFlush()

    let live = store.readAll()
    // Live file should contain the most recent write.
    #expect(live.contains("after-rotate"))
    // The archived file (unison.1.log) must exist.
    #expect(archiveFileExists(in: store, slot: 1))
}

@Test func fileLogStore_keepsAtMostMaxFiles() async throws {
    let store = makeTempStore(maxFileBytes: 50, maxFiles: 3)
    for i in 0..<20 {
        store.write(category: "Cat", level: "info", message: "line-\(i)-\(repeated("z", 40))")
    }
    await waitForFlush()
    store.rotateNow()

    let logFiles = logFileNames(in: store)
    // Live + (maxFiles - 1) archives at most. `rotateNow` may shift the
    // live file into `unison.1.log` and create a fresh live file, so
    // the upper bound is `maxFiles + 1` in the worst case (one rotation
    // tick after the keep-window check).
    #expect(logFiles.count <= store.maxFiles + 1,
            "expected at most \(store.maxFiles + 1) log files, got \(logFiles.count): \(logFiles)")
}

@Test func fileLogStore_formatIncludesTimestampCategoryLevel() async throws {
    let store = makeTempStore()
    store.write(category: "Orchestrator", level: "error", message: "boom")
    await waitForFlush()
    let contents = store.readAll()
    // Expected shape: "YYYY-MM-DD HH:MM:SS.mmm [Orchestrator:error] boom"
    // Use a substring check on the bracketed prefix; verifying the
    // timestamp shape via Regex needs `_Testing_Foundation`.
    #expect(contents.contains("[Orchestrator:error] boom"))
}

@Test func unisonLog_writesToFileStoreUnderRightCategory() async throws {
    // `UnisonLog` uses the shared singleton, so we can't redirect it
    // per-test. Verify by writing a unique sentinel string and grepping
    // the shared file for it.
    let sentinel = makeSentinel()
    let logger = UnisonLog(category: "TestProbe")
    logger.info(sentinel)
    await waitForFlush()

    let contents = FileLogStore.shared.readAll()
    #expect(contents.contains("[TestProbe:info]"))
    #expect(contents.contains(sentinel))
}
