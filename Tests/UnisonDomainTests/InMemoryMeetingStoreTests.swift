import Foundation
import Testing
@testable import UnisonDomain

@Test func inMemoryStore_saveAndLoad() throws {
    let store = InMemoryMeetingStore()
    let rec = sampleRecord(title: "A", entries: [sampleEntry()])
    store.save(rec)
    #expect(try store.load(rec.id) == rec)
}

@Test func inMemoryStore_load_missing_throws() {
    let store = InMemoryMeetingStore()
    #expect(throws: MeetingStoreError.notFound) { _ = try store.load(UUID()) }
}

@Test func inMemoryStore_list_pinnedFirstThenRecent() {
    let store = InMemoryMeetingStore()
    let oldUnpinned = recordAt(daysAgo: 5)
    let newUnpinned = recordAt(daysAgo: 1)
    let oldPinned = recordAt(daysAgo: 9, pinned: true)
    store.save(oldUnpinned); store.save(newUnpinned); store.save(oldPinned)
    #expect(store.list().map(\.id) == [oldPinned.id, newUnpinned.id, oldUnpinned.id])
}

@Test func inMemoryStore_rename_updatesTitle() throws {
    let store = InMemoryMeetingStore()
    let rec = sampleRecord(title: nil, entries: [sampleEntry()])
    store.save(rec)
    store.rename(rec.id, title: "Renamed")
    #expect(try store.load(rec.id).title == "Renamed")
}

@Test func inMemoryStore_setPinned_updatesFlag() throws {
    let store = InMemoryMeetingStore()
    let rec = sampleRecord(entries: [sampleEntry()])
    store.save(rec)
    store.setPinned(rec.id, true)
    #expect(try store.load(rec.id).pinned == true)
}

@Test func inMemoryStore_search_matchesTitleAndBody() {
    let store = InMemoryMeetingStore()
    store.save(sampleRecord(title: "Планёрка", entries: [sampleEntry(.peer, "обсудили деплой")]))
    store.save(sampleRecord(title: "Интервью", entries: [sampleEntry(.peer, "вопросы по Swift")]))
    #expect(store.search("деплой").count == 1)
    #expect(store.search("swift").count == 1)
    #expect(store.search("планёрка").count == 1)
    #expect(store.search("zzz").isEmpty)
}

@Test func inMemoryStore_clearAll_empties() {
    let store = InMemoryMeetingStore()
    store.save(sampleRecord(entries: [sampleEntry()]))
    store.clearAll()
    #expect(store.list().isEmpty)
}
