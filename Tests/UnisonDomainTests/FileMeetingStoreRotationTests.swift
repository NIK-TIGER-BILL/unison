import Foundation
import Testing
@testable import UnisonDomain

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("FileMeetingStoreRotationTests-\(UUID().uuidString)", isDirectory: true)
}

@Test func fileStore_search_titleAndFullText() {
    let store = FileMeetingStore(directory: tempDir(), sizeLimitMBProvider: { 0 })
    store.save(sampleRecord(title: "Планёрка", entries: [sampleEntry(.peer, "обсудили деплой пайплайна")]))
    store.save(sampleRecord(title: "Интервью", entries: [sampleEntry(.peer, "вопросы по Swift конкуренции")]))
    #expect(store.search("планёрка").count == 1)   // index fast-pass (title)
    #expect(store.search("деплой").count == 1)      // full-text pass (body)
    #expect(store.search("swift").count == 1)
    #expect(store.search("отсутствует").isEmpty)
}

@Test func fileStore_totalSizeBytes_sumsRecords() {
    let store = FileMeetingStore(directory: tempDir(), sizeLimitMBProvider: { 0 })
    store.save(sampleRecord(entries: [sampleEntry()]))
    store.save(sampleRecord(entries: [sampleEntry()]))
    #expect(store.totalSizeBytes() > 0)
}

@Test func fileStore_save_enforcesSizeLimit_evictsOldestKeepsNewest() {
    let store = FileMeetingStore(directory: tempDir(), sizeLimitMBProvider: { 1 })  // 1 MB cap
    // ~1.4 MB encoded per record (Cyrillic ≈ 2 bytes/char in UTF-8).
    let big = String(repeating: "слово ", count: 150_000)
    let old = recordAt(daysAgo: 5, entries: [sampleEntry(.peer, big)])
    let new = recordAt(daysAgo: 1, entries: [sampleEntry(.peer, big)])
    store.save(old)
    store.save(new)     // total > 1 MB → evict oldest (old), keep newest (new)
    let ids = store.list().map(\.id)
    #expect(ids.contains(new.id))
    #expect(!ids.contains(old.id))
}

@Test func fileStore_clearAll_removesEverything() {
    let store = FileMeetingStore(directory: tempDir(), sizeLimitMBProvider: { 0 })
    store.save(sampleRecord(entries: [sampleEntry()]))
    store.save(sampleRecord(entries: [sampleEntry()]))
    store.clearAll()
    #expect(store.list().isEmpty)
    #expect(store.totalSizeBytes() == 0)
}

@Test func fileStore_renameUpdate_doesNotEvictOverCap() {
    var limit = 0
    let store = FileMeetingStore(directory: tempDir(), sizeLimitMBProvider: { limit })
    let big = String(repeating: "слово ", count: 200_000)
    let old = recordAt(daysAgo: 5, entries: [sampleEntry(.peer, big)])
    let new = recordAt(daysAgo: 1, entries: [sampleEntry(.peer, big)])
    store.save(old); store.save(new)        // limit 0 → both present
    limit = 1                                // over the 1 MB cap
    store.rename(old.id, title: "Renamed")   // rename now uses update → must NOT evict
    #expect(store.list().contains { $0.id == old.id })
    #expect((try? store.load(old.id))?.title == "Renamed")
}
