import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
private func storeWith(_ records: [MeetingRecord]) -> InMemoryMeetingStore {
    let store = InMemoryMeetingStore()
    for r in records { store.save(r) }
    return store
}

@MainActor
@Test func historyVM_init_loadsAndSelectsFirst() {
    let a = recordAt(daysAgo: 1, entries: [sampleEntry()])
    let b = recordAt(daysAgo: 2, entries: [sampleEntry()])
    let vm = MeetingHistoryViewModel(store: storeWith([a, b]))
    #expect(vm.summaries.count == 2)
    #expect(vm.selectedID == a.id)          // newest first
    #expect(vm.selectedRecord?.id == a.id)
}

@MainActor
@Test func historyVM_emptyArchive_flag() {
    let vm = MeetingHistoryViewModel(store: InMemoryMeetingStore())
    #expect(vm.isEmptyArchive)
    #expect(vm.selectedRecord == nil)
}

@MainActor
@Test func historyVM_rename_persistsAndRefreshes() {
    let rec = recordAt(daysAgo: 1, entries: [sampleEntry()])
    let vm = MeetingHistoryViewModel(store: storeWith([rec]))
    vm.rename(rec.id, to: "Планёрка")
    #expect(vm.summaries.first?.title == "Планёрка")
    #expect(vm.selectedRecord?.title == "Планёрка")
}

@MainActor
@Test func historyVM_rename_blankClearsTitle() {
    let rec = recordAt(daysAgo: 1, entries: [sampleEntry()])
    let vm = MeetingHistoryViewModel(store: storeWith([rec]))
    vm.rename(rec.id, to: "  ")
    #expect(vm.selectedRecord?.title == nil)
}

@MainActor
@Test func historyVM_togglePin_reordersToTop() {
    let older = recordAt(daysAgo: 5, entries: [sampleEntry()])
    let newer = recordAt(daysAgo: 1, entries: [sampleEntry()])
    let vm = MeetingHistoryViewModel(store: storeWith([older, newer]))
    #expect(vm.summaries.first?.id == newer.id)
    vm.togglePin(older.id)
    #expect(vm.summaries.first?.id == older.id)   // pinned floats to top
    #expect(vm.summaries.first?.pinned == true)
}

@MainActor
@Test func historyVM_deleteMeeting_removesAndMovesSelection() {
    let a = recordAt(daysAgo: 1, entries: [sampleEntry()])
    let b = recordAt(daysAgo: 2, entries: [sampleEntry()])
    let vm = MeetingHistoryViewModel(store: storeWith([a, b]))
    vm.deleteMeeting(a.id)                          // a was selected (newest)
    #expect(vm.summaries.map(\.id) == [b.id])
    #expect(vm.selectedID == b.id)
}

@MainActor
@Test func historyVM_deleteLine_removesEntryFromSelected() {
    let e1 = sampleEntry(.peer, "Один")
    let e2 = sampleEntry(.me, "Два")
    let rec = recordAt(daysAgo: 1, entries: [e1, e2])
    let vm = MeetingHistoryViewModel(store: storeWith([rec]))
    vm.deleteLine(e1.id)
    #expect(vm.selectedRecord?.entries.map(\.id) == [e2.id])
    #expect(vm.summaries.first?.lineCount == 1)
}

@MainActor
@Test func historyVM_editLine_updatesTextAndMarksEdited() {
    let e1 = sampleEntry(.peer, "Старый текст")
    let rec = recordAt(daysAgo: 1, entries: [e1])
    let vm = MeetingHistoryViewModel(store: storeWith([rec]))
    vm.editLine(e1.id, newText: "Новый текст")
    let entry = vm.selectedRecord?.entries.first
    #expect(entry?.translatedText == "Новый текст")
    #expect(entry?.edited == true)
}

@MainActor
@Test func historyVM_search_filtersList() {
    let a = recordAt(daysAgo: 1, entries: [sampleEntry(.peer, "обсудили деплой")])
    let b = recordAt(daysAgo: 2, entries: [sampleEntry(.peer, "разговор о найме")])
    let vm = MeetingHistoryViewModel(store: storeWith([a, b]))
    vm.query = "деплой"
    #expect(vm.summaries.map(\.id) == [a.id])
}

@MainActor
@Test func historyVM_clearAll_empties() {
    let vm = MeetingHistoryViewModel(store: storeWith([recordAt(daysAgo: 1, entries: [sampleEntry()])]))
    vm.clearAll()
    #expect(vm.summaries.isEmpty)
    #expect(vm.selectedRecord == nil)
}
