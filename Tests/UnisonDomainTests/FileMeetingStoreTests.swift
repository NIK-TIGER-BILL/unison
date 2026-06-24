import Foundation
import Testing
@testable import UnisonDomain

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("FileMeetingStoreTests-\(UUID().uuidString)", isDirectory: true)
}
private func makeTempStore(limitMB: Int = 0) -> FileMeetingStore {
    FileMeetingStore(directory: tempDir(), sizeLimitMBProvider: { limitMB })
}

@Test func fileStore_saveLoad_roundTrips() throws {
    let store = makeTempStore()
    let rec = sampleRecord(title: "A", entries: [sampleEntry(), sampleEntry(.me, "Ок")])
    store.save(rec)
    #expect(try store.load(rec.id) == rec)
    #expect(store.list().map(\.id) == [rec.id])
}

@Test func fileStore_delete_removesRecordAndIndexEntry() {
    let store = makeTempStore()
    let rec = sampleRecord(entries: [sampleEntry()])
    store.save(rec)
    store.delete(rec.id)
    #expect(store.list().isEmpty)
    #expect(throws: MeetingStoreError.notFound) { _ = try store.load(rec.id) }
}

@Test func fileStore_rename_persists() throws {
    let store = makeTempStore()
    let rec = sampleRecord(title: nil, entries: [sampleEntry()])
    store.save(rec)
    store.rename(rec.id, title: "Renamed")
    #expect(try store.load(rec.id).title == "Renamed")
    #expect(store.list().first?.title == "Renamed")
}

@Test func fileStore_setPinned_persists() throws {
    let store = makeTempStore()
    let rec = sampleRecord(entries: [sampleEntry()])
    store.save(rec)
    store.setPinned(rec.id, true)
    #expect(try store.load(rec.id).pinned == true)
}

@Test func fileStore_reopen_readsPersistedIndex() throws {
    let dir = tempDir()
    let rec = sampleRecord(title: "Persisted", entries: [sampleEntry()])
    FileMeetingStore(directory: dir, sizeLimitMBProvider: { 0 }).save(rec)
    let reopened = FileMeetingStore(directory: dir, sizeLimitMBProvider: { 0 })
    #expect(reopened.list().map(\.id) == [rec.id])
    #expect(try reopened.load(rec.id) == rec)
}

@Test func fileStore_selfHeal_adoptsOrphanAndDropsDangling() throws {
    let dir = tempDir()
    let store = FileMeetingStore(directory: dir, sizeLimitMBProvider: { 0 })
    let rec = sampleRecord(entries: [sampleEntry()])
    store.save(rec)
    // Overwrite index.json with a dangling entry (no backing file) and
    // omit the real record's entry. JSONEncoder encodes Date as a Double
    // (seconds since reference date) — a bare number decodes fine.
    let danglingID = UUID()
    let badIndex = """
    {"schemaVersion":1,"meetings":[{"id":"\(danglingID.uuidString)","startedAt":0,"durationSeconds":0,"mode":"call","languagePair":{"mine":"ru","peer":"en"},"lineCount":0,"preview":"","pinned":false,"sizeBytes":0}]}
    """.data(using: .utf8)!
    try badIndex.write(to: dir.appendingPathComponent("index.json"))
    let reopened = FileMeetingStore(directory: dir, sizeLimitMBProvider: { 0 })
    let ids = reopened.list().map(\.id)
    #expect(ids == [rec.id])
    #expect(!ids.contains(danglingID))
}
