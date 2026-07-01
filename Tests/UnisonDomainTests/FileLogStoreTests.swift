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
    // Redirect UnisonLog's file sink to a temp store so the test never
    // touches the user's real `~/Library/Logs/Unison` (the shared store
    // is muted under `swift test` anyway). Restore afterwards.
    let temp = makeTempStore()
    let saved = UnisonLog.fileSink
    UnisonLog.fileSink = temp
    defer { UnisonLog.fileSink = saved }

    let sentinel = makeSentinel()
    UnisonLog(category: "TestProbe").info(sentinel)
    await waitForFlush()

    let contents = temp.readAll()
    #expect(contents.contains("[TestProbe:info]"))
    #expect(contents.contains(sentinel))
}

@Test func fileLogStore_concurrentWritesFromManyThreads_allLandIntact() async throws {
    // Regression guard for the "format the timestamp OFF the caller thread"
    // fix. Before it, `write()` formatted a SHARED, non-thread-safe
    // `DateFormatter` synchronously on the caller — so concurrent logging
    // from the two audio pumps + the CoreAudio render thread + the MainActor
    // + the WS loop raced on the formatter's internal state (undefined
    // behaviour) AND serialized on its lock, stalling whichever hot thread
    // lost the race → stuttered playback. Now the caller only snapshots a
    // lock-free `Date()`; all formatting happens on the single serial I/O
    // queue. Hammer write() from many threads at once and assert every line
    // lands intact and well-formed — no crash, no torn/corrupted lines.
    let store = makeTempStore(maxFileBytes: 8 * 1024 * 1024) // large: no rotation mid-test
    let threads = 8, perThread = 250
    await withTaskGroup(of: Void.self) { group in
        for t in 0..<threads {
            group.addTask {
                for i in 0..<perThread {
                    store.write(category: "T\(t)", level: "info", message: "msg-\(t)-\(i)")
                }
            }
        }
    }
    // Poll until the serial queue drains (robust vs a fixed sleep).
    let expected = threads * perThread
    for _ in 0..<50 {
        let landed = store.readAll().split(separator: "\n").filter { $0.contains(":info] msg-") }.count
        if landed >= expected { break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let contents = store.readAll()
    // Every unique (thread,index) line present.
    var missing = 0
    for t in 0..<threads {
        for i in 0..<perThread where !contents.contains("[T\(t):info] msg-\(t)-\(i)") { missing += 1 }
    }
    #expect(missing == 0, "\(missing) of \(expected) lines missing under concurrent logging")
    // Every emitted line carries a well-formed "YYYY-MM-DD HH:MM:SS.mmm "
    // prefix — a concurrently-corrupted DateFormatter would have torn it.
    var malformed = 0
    for line in contents.split(separator: "\n") where line.contains(":info] msg-") {
        let p = String(line.prefix(23))
        if !(p.hasPrefix("20") && p.contains("-") && p.contains(":") && p.contains(".")) { malformed += 1 }
    }
    #expect(malformed == 0, "\(malformed) lines had a malformed timestamp prefix")
}
