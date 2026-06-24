import Foundation
import Observation
import UnisonDomain

/// Drives the meeting-archive window. Pure logic over a `MeetingStore`;
/// no AppKit. All mutations write through the store and re-read so the
/// list + open record stay consistent.
@MainActor
@Observable
public final class MeetingHistoryViewModel {
    private let store: any MeetingStore

    public private(set) var summaries: [MeetingSummary] = []
    public var query: String = "" {
        didSet { guard query != oldValue else { return }; reload() }
    }
    public var selectedID: UUID? {
        didSet { guard selectedID != oldValue else { return }; loadSelected() }
    }
    public private(set) var selectedRecord: MeetingRecord?

    public init(store: any MeetingStore) {
        self.store = store
        reload()
    }

    /// Re-read the list (honoring the search query) and keep a valid
    /// selection — preserving it when still present, else selecting the
    /// first row.
    public func reload() {
        summaries = query.isEmpty ? store.list() : store.search(query)
        if selectedID == nil || !summaries.contains(where: { $0.id == selectedID }) {
            selectedID = summaries.first?.id
        } else {
            loadSelected()
        }
    }

    private func loadSelected() {
        guard let id = selectedID else { selectedRecord = nil; return }
        selectedRecord = try? store.load(id)
    }

    public func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        store.rename(id, title: t.isEmpty ? nil : t)
        reload()
    }

    public func togglePin(_ id: UUID) {
        guard let s = summaries.first(where: { $0.id == id }) else { return }
        store.setPinned(id, !s.pinned)
        reload()
    }

    public func deleteMeeting(_ id: UUID) {
        store.delete(id)
        reload()
    }

    public func deleteLine(_ entryID: UUID) {
        guard var rec = selectedRecord else { return }
        rec.entries.removeAll { $0.id == entryID }
        store.save(rec)
        reload()
    }

    public func editLine(_ entryID: UUID, newText: String) {
        guard var rec = selectedRecord,
              let i = rec.entries.firstIndex(where: { $0.id == entryID }) else { return }
        rec.entries[i].translatedText = newText
        rec.entries[i].edited = true
        store.save(rec)
        reload()
    }

    public func clearAll() {
        store.clearAll()
        reload()
    }

    public var isEmptyArchive: Bool { summaries.isEmpty && query.isEmpty }
}
