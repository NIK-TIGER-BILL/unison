import Foundation

/// File-backed `MeetingStore`. Layout under `directory`:
///   - `<uuid>.json`  — one full `MeetingRecord`
///   - `index.json`   — `{ schemaVersion, meetings: [MeetingSummary] }`
/// Writes are atomic (`Data.write(.atomic)`); the index self-heals against
/// the on-disk record files on construction. Thread-safe via a recursive
/// lock so public methods can compose (e.g. `save` → `enforceSizeLimit`
/// → `delete`).
public final class FileMeetingStore: MeetingStore, @unchecked Sendable {
    private struct Index: Codable {
        var schemaVersion: Int
        var meetings: [MeetingSummary]
    }

    private let lock = NSRecursiveLock()
    private let directory: URL
    private let indexURL: URL
    private let sizeLimitMBProvider: () -> Int
    private let fm = FileManager.default

    public init(directory: URL, sizeLimitMBProvider: @escaping () -> Int) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent("index.json")
        self.sizeLimitMBProvider = sizeLimitMBProvider
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        rebuildIndex()
    }

    /// Production location: ~/Library/Application Support/<bundleID>/meetings
    public static func applicationSupport(
        bundleID: String = "com.unison.app",
        sizeLimitMBProvider: @escaping () -> Int
    ) -> FileMeetingStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
                      .appendingPathComponent("meetings", isDirectory: true)
        return FileMeetingStore(directory: dir, sizeLimitMBProvider: sizeLimitMBProvider)
    }

    private func recordURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
    private func decodeRecord(at url: URL) throws -> MeetingRecord {
        try JSONDecoder().decode(MeetingRecord.self, from: try Data(contentsOf: url))
    }
    private func loadIndex() -> Index {
        guard let data = try? Data(contentsOf: indexURL),
              let idx = try? JSONDecoder().decode(Index.self, from: data) else {
            return Index(schemaVersion: MeetingRecord.currentSchemaVersion, meetings: [])
        }
        return idx
    }
    private func writeIndex(_ index: Index) {
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    /// Reconcile the index with the record files on disk: drop entries
    /// whose file is gone, adopt record files missing from the index.
    private func rebuildIndex() {
        lock.lock(); defer { lock.unlock() }
        var index = loadIndex()
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let recordFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
        let fileIDs = Set(recordFiles.compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent) })
        let indexedIDs = Set(index.meetings.map(\.id))

        index.meetings.removeAll { !fileIDs.contains($0.id) }
        for id in fileIDs.subtracting(indexedIDs) {
            guard let rec = try? decodeRecord(at: recordURL(id)) else { continue }
            let attrs = try? fm.attributesOfItem(atPath: recordURL(id).path)
            let size = (attrs?[.size] as? Int) ?? 0
            index.meetings.append(MeetingSummary(record: rec, sizeBytes: size))
        }
        index.schemaVersion = MeetingRecord.currentSchemaVersion
        writeIndex(index)
    }

    public func list() -> [MeetingSummary] {
        lock.lock(); defer { lock.unlock() }
        return loadIndex().meetings.sortedForList()
    }

    public func load(_ id: UUID) throws -> MeetingRecord {
        lock.lock(); defer { lock.unlock() }
        do { return try decodeRecord(at: recordURL(id)) }
        catch { throw MeetingStoreError.notFound }
    }

    public func save(_ record: MeetingRecord) {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(record) else { return }
        do { try data.write(to: recordURL(record.id), options: .atomic) } catch { return }
        var index = loadIndex()
        index.meetings.removeAll { $0.id == record.id }
        index.meetings.append(MeetingSummary(record: record, sizeBytes: data.count))
        writeIndex(index)
        enforceSizeLimit()
    }

    public func delete(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        try? fm.removeItem(at: recordURL(id))
        var index = loadIndex()
        index.meetings.removeAll { $0.id == id }
        writeIndex(index)
    }

    public func rename(_ id: UUID, title: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var rec = try? decodeRecord(at: recordURL(id)) else { return }
        rec.title = title
        save(rec)
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard var rec = try? decodeRecord(at: recordURL(id)) else { return }
        rec.pinned = pinned
        save(rec)
    }

    public func search(_ query: String) -> [MeetingSummary] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock(); defer { lock.unlock() }
        let all = loadIndex().meetings
        guard !q.isEmpty else { return all.sortedForList() }
        var matched = Set(all.filter {
            $0.displayTitle.lowercased().contains(q) || $0.preview.lowercased().contains(q)
        }.map(\.id))
        for s in all where !matched.contains(s.id) {
            guard let rec = try? decodeRecord(at: recordURL(s.id)) else { continue }
            if rec.entries.contains(where: {
                $0.translatedText.lowercased().contains(q)
                || ($0.originalText?.lowercased().contains(q) ?? false)
            }) { matched.insert(s.id) }
        }
        return all.filter { matched.contains($0.id) }.sortedForList()
    }

    public func totalSizeBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        return loadIndex().meetings.reduce(0) { $0 + $1.sizeBytes }
    }

    public func enforceSizeLimit() {
        lock.lock(); defer { lock.unlock() }
        for id in meetingsToEvict(loadIndex().meetings, limitMB: sizeLimitMBProvider()) {
            delete(id)
        }
    }

    public func clearAll() {
        lock.lock(); defer { lock.unlock() }
        for s in loadIndex().meetings { try? fm.removeItem(at: recordURL(s.id)) }
        writeIndex(Index(schemaVersion: MeetingRecord.currentSchemaVersion, meetings: []))
    }
}
