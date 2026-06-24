import Foundation

public enum MeetingStoreError: Error, Equatable { case notFound }

public protocol MeetingStore: Sendable {
    func list() -> [MeetingSummary]
    func load(_ id: UUID) throws -> MeetingRecord
    func save(_ record: MeetingRecord)
    func delete(_ id: UUID)
    func rename(_ id: UUID, title: String?)
    func setPinned(_ id: UUID, _ pinned: Bool)
    func search(_ query: String) -> [MeetingSummary]
    func totalSizeBytes() -> Int
    func enforceSizeLimit()
    func clearAll()
}

extension Array where Element == MeetingSummary {
    /// List order: pinned first, then most-recent first.
    public func sortedForList() -> [MeetingSummary] {
        sorted { a, b in
            if a.pinned != b.pinned { return a.pinned && !b.pinned }
            return a.startedAt > b.startedAt
        }
    }
}

/// In-memory `MeetingStore`. Used as a test fake and as the orchestrator's
/// default so non-archiving call sites (and existing tests) keep compiling.
public final class InMemoryMeetingStore: MeetingStore, @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var records: [UUID: MeetingRecord] = [:]
    private let sizeLimitMBProvider: () -> Int

    public init(sizeLimitMBProvider: @escaping () -> Int = { 0 }) {
        self.sizeLimitMBProvider = sizeLimitMBProvider
    }

    private func sizeBytes(_ record: MeetingRecord) -> Int {
        (try? JSONEncoder().encode(record).count) ?? 0
    }
    private func summary(_ record: MeetingRecord) -> MeetingSummary {
        MeetingSummary(record: record, sizeBytes: sizeBytes(record))
    }

    public func list() -> [MeetingSummary] {
        lock.lock(); defer { lock.unlock() }
        return records.values.map(summary).sortedForList()
    }
    public func load(_ id: UUID) throws -> MeetingRecord {
        lock.lock(); defer { lock.unlock() }
        guard let r = records[id] else { throw MeetingStoreError.notFound }
        return r
    }
    public func save(_ record: MeetingRecord) {
        lock.lock(); defer { lock.unlock() }
        records[record.id] = record
        enforceSizeLimit()
    }
    public func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        records[id] = nil
    }
    public func rename(_ id: UUID, title: String?) {
        lock.lock(); defer { lock.unlock() }
        records[id]?.title = title
    }
    public func setPinned(_ id: UUID, _ pinned: Bool) {
        lock.lock(); defer { lock.unlock() }
        records[id]?.pinned = pinned
    }
    public func search(_ query: String) -> [MeetingSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock(); defer { lock.unlock() }
        guard !q.isEmpty else { return records.values.map(summary).sortedForList() }
        return records.values.filter { record in
            record.displayTitle.lowercased().contains(q)
            || record.entries.contains {
                $0.translatedText.lowercased().contains(q)
                || ($0.originalText?.lowercased().contains(q) ?? false)
            }
        }.map(summary).sortedForList()
    }
    public func totalSizeBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.values.reduce(0) { $0 + sizeBytes($1) }
    }
    public func enforceSizeLimit() {
        lock.lock(); defer { lock.unlock() }
        let summaries = records.values.map(summary)
        for id in meetingsToEvict(summaries, limitMB: sizeLimitMBProvider()) {
            records[id] = nil
        }
    }
    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }
}
