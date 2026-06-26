# Meeting History — Part 1: Persistence Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every real (`.call`/`.listen`) translation session to disk as an editable, searchable meeting record with size-based rotation — entirely headless, no UI.

**Architecture:** New domain types (`MeetingRecord`, `MeetingSummary`), a `MeetingStore` protocol with a file-backed implementation (`FileMeetingStore`: one JSON per meeting + a lightweight `index.json`, self-healing, atomic writes) and an in-memory implementation (`InMemoryMeetingStore`, used as a test fake and the orchestrator's default). A pure rotation function decides eviction. The orchestrator archives the just-ended session in `stop()`. `Composition` wires the real file store.

**Tech Stack:** Swift 6.2 toolchain / Swift 5 language mode, SwiftPM, swift-testing (`import Testing`, `@Test`, `#expect`). Tests run via `./scripts/test.sh --filter <name>` (CI uses `swift test --parallel`).

---

## Scope

This is **Part 1 of 2**. It produces working, independently-testable software: sessions persist across app restarts and rotate by size. There is no in-app way to view them yet — that is **Part 2 (UI)** (window, list/detail editor, menu entry, hotkey, Settings section), written as a separate plan against the store this part builds.

## File Structure

**New source files (all in `Sources/UnisonDomain/`):**

| File | Responsibility |
| --- | --- |
| `MeetingRecord.swift` | `MeetingRecord` (full meeting) + `MeetingSummary` (index row) + display-title/auto-title + summary derivation. Codable value types only. |
| `MeetingRotation.swift` | `meetingsToEvict(_:limitMB:)` — pure size-rotation policy. |
| `MeetingStore.swift` | `MeetingStore` protocol, `MeetingStoreError`, `[MeetingSummary].sortedForList()`, and `InMemoryMeetingStore` (fake + orchestrator default). |
| `FileMeetingStore.swift` | File-backed `MeetingStore`: per-meeting JSON + `index.json`, atomic writes, self-healing index, search, rotation. |

**Modified source files:**

| File | Change |
| --- | --- |
| `Sources/UnisonDomain/TranscriptEntry.swift` | `+ Codable` conformance, `+ edited: Bool` field. |
| `Sources/UnisonDomain/Settings.swift` | `+ saveHistoryEnabled: Bool`, `+ historySizeLimitMB: Int` (+ CodingKeys + `decodeIfPresent`). |
| `Sources/UnisonDomain/TranslationOrchestrator.swift` | `+ meetingStore` (injected, defaulted), `+ archiveSession(...)`, call it from `stop()`. |
| `Sources/UnisonApp/Composition.swift` | Construct `FileMeetingStore`, inject into orchestrator, expose `meetingStore`, sweep at launch. |

**New test files (all in `Tests/UnisonDomainTests/`):**
`MeetingTestSupport.swift` (shared builders), `TranscriptEntryCodableTests.swift`, `MeetingRecordTests.swift`, `MeetingRotationTests.swift`, `InMemoryMeetingStoreTests.swift`, `FileMeetingStoreTests.swift`, `FileMeetingStoreRotationTests.swift`, `SettingsHistoryTests.swift`, `OrchestratorArchiveTests.swift`.

**Conventions to follow (verified in-repo):**
- swift-testing free functions: `@Test func name() { #expect(...) }`, `@MainActor` on the function when the type is `@MainActor`, `async` when needed.
- JSON round-trip helper already exists: `encodeDecode<T: Codable>(_:)` in `Tests/UnisonDomainTests/CodableHelpers.swift`.
- Temp-dir pattern: `FileManager.default.temporaryDirectory.appendingPathComponent("X-\(UUID().uuidString)", isDirectory: true)` (no teardown needed; OS cleans temp).
- Mocks live in `Tests/UnisonDomainTests/Mocks/` (e.g. `MockMicrophoneCapture`, `MockNetworkPathMonitor`, `MockPermissionsService`).

---

## Task 1: `TranscriptEntry` → Codable + `edited`

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptEntry.swift`
- Test: `Tests/UnisonDomainTests/TranscriptEntryCodableTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/TranscriptEntryCodableTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@Test func transcriptEntry_codableRoundTrip_preservesAllFields() throws {
    let entry = TranscriptEntry(
        id: UUID(),
        speaker: .peer,
        originalText: "Hello",
        translatedText: "Привет",
        sourceLanguage: .en,
        targetLanguage: .ru,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        lastActivityAt: Date(timeIntervalSince1970: 1_700_000_005),
        translationAtRisk: true
    )
    let decoded: TranscriptEntry = try encodeDecode(entry)
    #expect(decoded == entry)
    #expect(decoded.edited == false)
}

@Test func transcriptEntry_edited_roundTrips() throws {
    var entry = TranscriptEntry(
        id: UUID(), speaker: .me,
        originalText: nil, translatedText: "x",
        sourceLanguage: nil, targetLanguage: .en,
        timestamp: Date(timeIntervalSince1970: 1)
    )
    entry.edited = true
    let decoded: TranscriptEntry = try encodeDecode(entry)
    #expect(decoded.edited == true)
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter transcriptEntry_`
Expected: FAIL — compile error (`TranscriptEntry` does not conform to `Codable`; no member `edited`).

- [ ] **Step 3: Add Codable + `edited`**

In `Sources/UnisonDomain/TranscriptEntry.swift`, change the struct declaration and add the field + init parameter:

```swift
public struct TranscriptEntry: Identifiable, Sendable, Equatable, Codable {
```

Add after the `translationAtRisk` property (before `init`):

```swift
    /// Set when the user edits this entry's text in the meeting archive.
    /// Persisted with the record; ignored by the live transcript.
    public var edited: Bool
```

Add the init parameter (last, defaulted so existing call sites keep compiling) and assignment:

```swift
        translationAtRisk: Bool = false,
        edited: Bool = false
    ) {
```
```swift
        self.translationAtRisk = translationAtRisk
        self.edited = edited
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter transcriptEntry_`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptEntry.swift Tests/UnisonDomainTests/TranscriptEntryCodableTests.swift
git commit -m "feat(history): make TranscriptEntry Codable + add edited flag"
```

---

## Task 2: `MeetingRecord` + `MeetingSummary` + shared test builders

**Files:**
- Create: `Sources/UnisonDomain/MeetingRecord.swift`
- Create: `Tests/UnisonDomainTests/MeetingTestSupport.swift`
- Test: `Tests/UnisonDomainTests/MeetingRecordTests.swift`

- [ ] **Step 1: Create the shared test builders**

Create `Tests/UnisonDomainTests/MeetingTestSupport.swift` (reused by later tasks):

```swift
import Foundation
@testable import UnisonDomain

func sampleEntry(_ speaker: Speaker = .peer, _ translated: String = "Привет") -> TranscriptEntry {
    TranscriptEntry(
        id: UUID(), speaker: speaker, originalText: "Hi",
        translatedText: translated, sourceLanguage: .en, targetLanguage: .ru,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

func sampleRecord(
    title: String? = nil,
    mode: SessionMode = .call,
    entries: [TranscriptEntry] = []
) -> MeetingRecord {
    MeetingRecord(
        id: UUID(), title: title,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_001_920),   // +1920s
        mode: mode, languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: entries
    )
}

/// Record with a controllable start time (for ordering / rotation tests).
func recordAt(daysAgo: Double, pinned: Bool = false,
              entries: [TranscriptEntry] = [sampleEntry()]) -> MeetingRecord {
    let start = Date(timeIntervalSince1970: 2_000_000_000 - daysAgo * 86_400)
    return MeetingRecord(
        id: UUID(), title: nil, startedAt: start,
        endedAt: start.addingTimeInterval(60), mode: .call,
        languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: entries, pinned: pinned
    )
}
```

- [ ] **Step 2: Write the failing test**

Create `Tests/UnisonDomainTests/MeetingRecordTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@Test func meetingRecord_codableRoundTrip() throws {
    let rec = sampleRecord(title: "Синк", entries: [sampleEntry(), sampleEntry(.me, "Ок")])
    let decoded: MeetingRecord = try encodeDecode(rec)
    #expect(decoded == rec)
    #expect(decoded.schemaVersion == MeetingRecord.currentSchemaVersion)
}

@Test func meetingRecord_durationSeconds_computed() {
    #expect(sampleRecord().durationSeconds == 1920)
}

@Test func meetingRecord_displayTitle_usesCustomTitleWhenSet() {
    #expect(sampleRecord(title: "Синк с командой").displayTitle == "Синк с командой")
}

@Test func meetingRecord_displayTitle_autoForCall() {
    #expect(sampleRecord(title: nil, mode: .call).displayTitle.hasPrefix("Звонок · "))
}

@Test func meetingRecord_displayTitle_autoForListen_blankTitleFallsBack() {
    #expect(sampleRecord(title: "   ", mode: .listen).displayTitle.hasPrefix("Прослушивание · "))
}

@Test func meetingSummary_fromRecord_derivesFields() {
    var rec = sampleRecord(title: "T", entries: [sampleEntry(.peer, "Первая реплика"), sampleEntry(.me, "Вторая")])
    rec.pinned = true
    let s = MeetingSummary(record: rec, sizeBytes: 1234)
    #expect(s.lineCount == 2)
    #expect(s.preview == "Первая реплика")
    #expect(s.pinned == true)
    #expect(s.sizeBytes == 1234)
    #expect(s.durationSeconds == 1920)
}

@Test func meetingSummary_preview_truncatesLongFirstLine() {
    let long = String(repeating: "а", count: 200)
    let s = MeetingSummary(record: sampleRecord(entries: [sampleEntry(.peer, long)]), sizeBytes: 0)
    #expect(s.preview.count == 81)        // 80 chars + ellipsis
    #expect(s.preview.hasSuffix("…"))
}
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `./scripts/test.sh --filter meeting`
Expected: FAIL — compile error (no type `MeetingRecord` / `MeetingSummary`).

- [ ] **Step 4: Implement `MeetingRecord.swift`**

Create `Sources/UnisonDomain/MeetingRecord.swift`:

```swift
import Foundation

/// One archived translation session: full transcript + metadata.
public struct MeetingRecord: Identifiable, Sendable, Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let id: UUID
    public var title: String?
    public let startedAt: Date
    public let endedAt: Date
    public let mode: SessionMode
    public let languagePair: LanguagePair
    public var entries: [TranscriptEntry]
    public var pinned: Bool
    public let schemaVersion: Int

    public init(
        id: UUID,
        title: String?,
        startedAt: Date,
        endedAt: Date,
        mode: SessionMode,
        languagePair: LanguagePair,
        entries: [TranscriptEntry],
        pinned: Bool = false,
        schemaVersion: Int = MeetingRecord.currentSchemaVersion
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.languagePair = languagePair
        self.entries = entries
        self.pinned = pinned
        self.schemaVersion = schemaVersion
    }

    public var durationSeconds: Int {
        max(0, Int(endedAt.timeIntervalSince(startedAt).rounded()))
    }

    public var displayTitle: String { Self.displayTitle(title: title, mode: mode, startedAt: startedAt) }

    static func displayTitle(title: String?, mode: SessionMode, startedAt: Date) -> String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        return "\(modeWord(mode)) · \(titleDateFormatter.string(from: startedAt))"
    }

    static func modeWord(_ mode: SessionMode) -> String {
        switch mode {
        case .call: return "Звонок"
        case .listen: return "Прослушивание"
        case .test: return "Тест"
        }
    }

    static let titleDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.setLocalizedDateFormatFromTemplate("d MMMM, HH:mm")
        return f
    }()
}

/// Lightweight index row for list rendering without loading the full record.
public struct MeetingSummary: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public var title: String?
    public let startedAt: Date
    public let durationSeconds: Int
    public let mode: SessionMode
    public let languagePair: LanguagePair
    public var lineCount: Int
    public var preview: String
    public var pinned: Bool
    public var sizeBytes: Int

    public init(
        id: UUID, title: String?, startedAt: Date, durationSeconds: Int,
        mode: SessionMode, languagePair: LanguagePair, lineCount: Int,
        preview: String, pinned: Bool, sizeBytes: Int
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.mode = mode
        self.languagePair = languagePair
        self.lineCount = lineCount
        self.preview = preview
        self.pinned = pinned
        self.sizeBytes = sizeBytes
    }

    public init(record: MeetingRecord, sizeBytes: Int) {
        self.init(
            id: record.id, title: record.title, startedAt: record.startedAt,
            durationSeconds: record.durationSeconds, mode: record.mode,
            languagePair: record.languagePair, lineCount: record.entries.count,
            preview: Self.previewText(from: record.entries),
            pinned: record.pinned, sizeBytes: sizeBytes
        )
    }

    public var displayTitle: String {
        MeetingRecord.displayTitle(title: title, mode: mode, startedAt: startedAt)
    }

    static func previewText(from entries: [TranscriptEntry], maxLength: Int = 80) -> String {
        guard let first = entries.first else { return "" }
        let text = first.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= maxLength ? text : String(text.prefix(maxLength)) + "…"
    }
}
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `./scripts/test.sh --filter meeting`
Expected: PASS (8 tests: 6 record + 2 summary).

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/MeetingRecord.swift Tests/UnisonDomainTests/MeetingTestSupport.swift Tests/UnisonDomainTests/MeetingRecordTests.swift
git commit -m "feat(history): add MeetingRecord and MeetingSummary domain types"
```

---

## Task 3: Size-rotation policy (pure function)

**Files:**
- Create: `Sources/UnisonDomain/MeetingRotation.swift`
- Test: `Tests/UnisonDomainTests/MeetingRotationTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/MeetingRotationTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

private func summary(_ id: UUID = UUID(), daysAgo: Double, sizeMB: Int, pinned: Bool = false) -> MeetingSummary {
    MeetingSummary(
        id: id, title: nil,
        startedAt: Date(timeIntervalSince1970: 2_000_000_000 - daysAgo * 86_400),
        durationSeconds: 60, mode: .call,
        languagePair: LanguagePair(mine: .ru, peer: .en),
        lineCount: 1, preview: "", pinned: pinned, sizeBytes: sizeMB * 1024 * 1024
    )
}

@Test func rotation_underLimit_evictsNothing() {
    let s = [summary(daysAgo: 1, sizeMB: 10), summary(daysAgo: 2, sizeMB: 10)]
    #expect(meetingsToEvict(s, limitMB: 50).isEmpty)
}

@Test func rotation_zeroLimit_evictsNothing() {
    let s = [summary(daysAgo: 1, sizeMB: 100), summary(daysAgo: 2, sizeMB: 100)]
    #expect(meetingsToEvict(s, limitMB: 0).isEmpty)
}

@Test func rotation_overLimit_evictsOldestFirst() {
    let newest = summary(daysAgo: 1, sizeMB: 20)
    let mid = UUID(); let old = UUID()
    let s = [newest, summary(mid, daysAgo: 2, sizeMB: 20), summary(old, daysAgo: 3, sizeMB: 20)]
    #expect(meetingsToEvict(s, limitMB: 50) == [old])   // 60MB → drop oldest 20 → 40 ≤ 50
}

@Test func rotation_neverEvictsNewest() {
    let newest = summary(daysAgo: 1, sizeMB: 60)         // alone exceeds the 50MB limit
    let s = [newest, summary(daysAgo: 2, sizeMB: 5)]
    #expect(!meetingsToEvict(s, limitMB: 50).contains(newest.id))
}

@Test func rotation_neverEvictsPinned() {
    let pinnedOld = summary(daysAgo: 5, sizeMB: 30, pinned: true)
    let newest = summary(daysAgo: 1, sizeMB: 30)
    let mid = UUID()
    let s = [pinnedOld, newest, summary(mid, daysAgo: 2, sizeMB: 30)]   // 90MB
    let evicted = meetingsToEvict(s, limitMB: 50)
    #expect(!evicted.contains(pinnedOld.id))
    #expect(evicted.contains(mid))
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter rotation_`
Expected: FAIL — compile error (no `meetingsToEvict`).

- [ ] **Step 3: Implement `MeetingRotation.swift`**

Create `Sources/UnisonDomain/MeetingRotation.swift`:

```swift
import Foundation

/// Pure size-rotation policy. Returns ids to evict (oldest first) so the
/// total drops to or below `limitMB`. Protections:
///  - `limitMB <= 0` → no rotation (empty result)
///  - pinned meetings are never evicted
///  - the newest meeting (max `startedAt`) is never evicted
///  - whole meetings only; a single oversized record is left in place
public func meetingsToEvict(_ summaries: [MeetingSummary], limitMB: Int) -> [UUID] {
    guard limitMB > 0 else { return [] }
    let limit = limitMB * 1024 * 1024
    var total = summaries.reduce(0) { $0 + $1.sizeBytes }
    guard total > limit else { return [] }

    let newestID = summaries.max(by: { $0.startedAt < $1.startedAt })?.id
    let candidates = summaries
        .filter { !$0.pinned && $0.id != newestID }
        .sorted { $0.startedAt < $1.startedAt }

    var evicted: [UUID] = []
    for c in candidates where total > limit {
        evicted.append(c.id)
        total -= c.sizeBytes
    }
    return evicted
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter rotation_`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/MeetingRotation.swift Tests/UnisonDomainTests/MeetingRotationTests.swift
git commit -m "feat(history): add pure size-rotation policy"
```

---

## Task 4: `MeetingStore` protocol + `InMemoryMeetingStore`

**Files:**
- Create: `Sources/UnisonDomain/MeetingStore.swift`
- Test: `Tests/UnisonDomainTests/InMemoryMeetingStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/InMemoryMeetingStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter inMemoryStore_`
Expected: FAIL — compile error (no `MeetingStore` / `InMemoryMeetingStore` / `MeetingStoreError`).

- [ ] **Step 3: Implement `MeetingStore.swift`**

Create `Sources/UnisonDomain/MeetingStore.swift`:

```swift
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
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter inMemoryStore_`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/MeetingStore.swift Tests/UnisonDomainTests/InMemoryMeetingStoreTests.swift
git commit -m "feat(history): add MeetingStore protocol + in-memory implementation"
```

---

## Task 5: `FileMeetingStore` — CRUD, index, atomic writes, self-healing

**Files:**
- Create: `Sources/UnisonDomain/FileMeetingStore.swift`
- Test: `Tests/UnisonDomainTests/FileMeetingStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/FileMeetingStoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter fileStore_`
Expected: FAIL — compile error (no `FileMeetingStore`).

- [ ] **Step 3: Implement `FileMeetingStore.swift`**

Create `Sources/UnisonDomain/FileMeetingStore.swift`:

```swift
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
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter fileStore_`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/FileMeetingStore.swift Tests/UnisonDomainTests/FileMeetingStoreTests.swift
git commit -m "feat(history): add file-backed MeetingStore with self-healing index"
```

---

## Task 6: `FileMeetingStore` — search, size, rotation, clearAll

**Files:**
- Test: `Tests/UnisonDomainTests/FileMeetingStoreRotationTests.swift`

(Implementation already landed in Task 5; this task locks the behaviour with tests. If a test fails, fix `FileMeetingStore.swift`.)

- [ ] **Step 1: Write the test**

Create `Tests/UnisonDomainTests/FileMeetingStoreRotationTests.swift`:

```swift
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
    store.save(old)     // alone > 1 MB, but it's the newest at this point → kept
    store.save(new)     // now two records > 1 MB → evict oldest (old), keep newest (new)
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
```

- [ ] **Step 2: Run the test, verify it passes**

Run: `./scripts/test.sh --filter fileStore_search_ fileStore_totalSizeBytes_ fileStore_save_enforces fileStore_clearAll_`
(or simply `./scripts/test.sh --filter fileStore_`)
Expected: PASS. If `fileStore_save_enforcesSizeLimit_evictsOldestKeepsNewest` fails, re-check `save()` calls `enforceSizeLimit()` and `meetingsToEvict` integration in `FileMeetingStore.swift`.

- [ ] **Step 3: Commit**

```bash
git add Tests/UnisonDomainTests/FileMeetingStoreRotationTests.swift
git commit -m "test(history): lock FileMeetingStore search + rotation behaviour"
```

---

## Task 7: `Settings` — history fields

**Files:**
- Modify: `Sources/UnisonDomain/Settings.swift`
- Test: `Tests/UnisonDomainTests/SettingsHistoryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/SettingsHistoryTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@Test func settings_history_defaults() {
    #expect(Settings.default.saveHistoryEnabled == true)
    #expect(Settings.default.historySizeLimitMB == 50)
}

@Test func settings_history_codableRoundTrip() throws {
    var s = Settings.default
    s.saveHistoryEnabled = false
    s.historySizeLimitMB = 100
    let decoded: Settings = try encodeDecode(s)
    #expect(decoded.saveHistoryEnabled == false)
    #expect(decoded.historySizeLimitMB == 100)
}

@Test func settings_history_legacyDecodeUsesDefaults() throws {
    let legacy = """
    {"sessionMode":"call","languagePair":{"mine":"ru","peer":"en"},"originalMixVolume":0.2}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Settings.self, from: legacy)
    #expect(decoded.saveHistoryEnabled == true)
    #expect(decoded.historySizeLimitMB == 50)
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter settings_history_`
Expected: FAIL — compile error (no `saveHistoryEnabled` / `historySizeLimitMB`).

- [ ] **Step 3: Add the fields to `Settings.swift`**

Add stored properties after `_originalMixVolume`:

```swift
    public var saveHistoryEnabled: Bool
    public var historySizeLimitMB: Int
```

Add init parameters (defaulted) and assignments. Change the init signature's tail:

```swift
        excludedTapBundleIDs: [String] = [],
        originalMixVolume: Float = 0.2,
        saveHistoryEnabled: Bool = true,
        historySizeLimitMB: Int = 50
    ) {
```

and append to the body:

```swift
        self._originalMixVolume = min(max(originalMixVolume, 0.0), 1.0)
        self.saveHistoryEnabled = saveHistoryEnabled
        self.historySizeLimitMB = historySizeLimitMB
    }
```

Extend `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case sessionMode, languagePair, inputDeviceUID, outputDeviceUID
        case excludedTapBundleIDs
        case _originalMixVolume = "originalMixVolume"
        case saveHistoryEnabled, historySizeLimitMB
    }
```

Extend the custom `init(from:)` (append before the closing brace, using `decodeIfPresent` for forward-compat with old JSON):

```swift
        self.saveHistoryEnabled = try c.decodeIfPresent(Bool.self, forKey: .saveHistoryEnabled) ?? true
        self.historySizeLimitMB = try c.decodeIfPresent(Int.self, forKey: .historySizeLimitMB) ?? 50
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter settings_history_`
Expected: PASS (3 tests). Also run the existing Settings tests to confirm no regression: `./scripts/test.sh --filter settings_`

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/Settings.swift Tests/UnisonDomainTests/SettingsHistoryTests.swift
git commit -m "feat(history): add saveHistoryEnabled + historySizeLimitMB settings"
```

---

## Task 8: Orchestrator archives on `stop()`

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Test: `Tests/UnisonDomainTests/OrchestratorArchiveTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/OrchestratorArchiveTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@MainActor
private func makeOrchestrator(store: any MeetingStore) -> TranslationOrchestrator {
    let registry = MockAudioDeviceRegistry()
    let perms = MockPermissionsService()
    perms.statuses[.microphone] = .granted
    return TranslationOrchestrator(
        micCapture: MockMicrophoneCapture(),
        peerCapture: MockPeerAudioCapture(),
        outputMixer: MockAudioOutputMixer(),
        virtualMicPlayer: MockAudioPlayer(),
        translationFactory: MockTranslationStreamFactory(),
        permissions: perms,
        deviceRegistry: registry,
        clock: SystemClock(),
        transformer: MockAudioFormatTransformer(),
        networkMonitor: MockNetworkPathMonitor(initial: .satisfied),
        meetingStore: store
    )
}

@MainActor
private func seedOneEntry(_ orch: TranslationOrchestrator) {
    orch.transcript.currentLanguagePair = .default
    orch.transcript.apply(TranscriptDelta(
        entryId: UUID(), speaker: .peer, kind: .translated, text: "Привет", isFinal: true))
}

@MainActor
@Test func archiveSession_savesCallWithEntries() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .call, startedAt: Date(timeIntervalSince1970: 1000), enabled: true)
    #expect(store.list().count == 1)
    #expect(store.list().first?.mode == .call)
    #expect(store.list().first?.lineCount == 1)
}

@MainActor
@Test func archiveSession_skipsTestMode() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .test, startedAt: Date(), enabled: true)
    #expect(store.list().isEmpty)
}

@MainActor
@Test func archiveSession_skipsEmptyTranscript() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    orch.archiveSession(mode: .call, startedAt: Date(), enabled: true)
    #expect(store.list().isEmpty)
}

@MainActor
@Test func archiveSession_skipsWhenDisabled() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveSession(mode: .call, startedAt: Date(), enabled: false)
    #expect(store.list().isEmpty)
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter archiveSession_`
Expected: FAIL — compile error (`TranslationOrchestrator` init has no `meetingStore:` parameter; no `archiveSession`).

- [ ] **Step 3: Wire the orchestrator**

In `Sources/UnisonDomain/TranslationOrchestrator.swift`:

(a) Add a stored property next to the other injected `private let`s (after `networkMonitor`, around line 105):

```swift
    private let meetingStore: any MeetingStore
```

(b) Add the init parameter (last, defaulted) — extend the init signature's parameter list:

```swift
        networkMonitor: any NetworkPathMonitoring,
        meetingStore: any MeetingStore = InMemoryMeetingStore()
    ) {
```

and assign in the init body (after `self.networkMonitor = networkMonitor`):

```swift
        self.meetingStore = meetingStore
```

(c) Add the archive method (place it right after `stop()`):

```swift
    /// Persist the just-ended session to the meeting archive. Internal so
    /// tests can drive it directly. No-op for `.test`, empty transcripts,
    /// or when history saving is disabled. Does NOT clear the transcript —
    /// the live view keeps showing it until the next `start()`.
    func archiveSession(mode: SessionMode?, startedAt: Date?, enabled: Bool) {
        guard enabled, let mode, mode != .test, let startedAt,
              !transcript.entries.isEmpty else { return }
        let record = MeetingRecord(
            id: UUID(), title: nil,
            startedAt: startedAt, endedAt: clock.now(),
            mode: mode,
            languagePair: transcript.currentLanguagePair ?? .default,
            entries: transcript.entries)
        meetingStore.save(record)
    }
```

(d) Call it from `stop()` — capture metadata before `state = .idle`, archive after teardown. Replace the body of `stop()` (around line 1328) with:

```swift
    public func stop() async {
        Self.log.info("stop() — tearing down session from state=\(String(describing: self.state))")
        let archivedMode = state.activeMode
        let archivedStart = state.sessionStartedAt
        await stopAllStreams()
        consecutiveEmptyCloses = [.me: 0, .peer: 0]
        state = .idle
        WireDumper.shared.close()
        WireDumper.sent.close()
        archiveSession(mode: archivedMode, startedAt: archivedStart,
                       enabled: currentSettings.saveHistoryEnabled)
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter archiveSession_`
Expected: PASS (4 tests).

- [ ] **Step 5: Run the full domain suite (no regressions)**

Run: `./scripts/test.sh --filter UnisonDomainTests`
Expected: PASS (existing orchestrator/transcript tests still green — the new init param is defaulted, so `makeOrchestrator` in `TranscriptViewModelTests` is unaffected).

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/TranslationOrchestrator.swift Tests/UnisonDomainTests/OrchestratorArchiveTests.swift
git commit -m "feat(history): archive session to MeetingStore on stop()"
```

---

## Task 9: Wire the real store in `Composition`

**Files:**
- Modify: `Sources/UnisonApp/Composition.swift`

(No unit test — `Composition` is the app's composition root. Verification = build + full suite green + a manual launch check.)

- [ ] **Step 1: Add the `meetingStore` property**

In `Sources/UnisonApp/Composition.swift`, add to the public stored properties (after `public let transcriptVM: TranscriptViewModel`, around line 54):

```swift
    public let meetingStore: any MeetingStore
```

- [ ] **Step 2: Construct it and inject into the orchestrator**

`settingsStoreRef` is already defined just above the orchestrator construction (line 151: `let settingsStoreRef = settingsStore`). Immediately before the `self.orchestrator = TranslationOrchestrator(...)` call (line 160), insert:

```swift
        let meetingStore = FileMeetingStore.applicationSupport(
            sizeLimitMBProvider: { settingsStoreRef.load().historySizeLimitMB }
        )
        self.meetingStore = meetingStore
```

Then add `meetingStore` as the final argument of the `TranslationOrchestrator(...)` initializer:

```swift
            transformer: ResamplerAdapter(),
            networkMonitor: NetworkMonitor(),
            meetingStore: meetingStore
        )
```

- [ ] **Step 3: Sweep at launch**

At the very end of `init()` (after `wireCrossSurfaceSync()` / the force-state block, just before the closing brace of `init`), add a one-time rotation sweep so a limit lowered while the app was closed takes effect:

```swift
        meetingStore.enforceSizeLimit()
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build`
Expected: builds with no errors.

Run: `./scripts/test.sh`
Expected: entire suite PASS.

- [ ] **Step 5: Manual smoke check (real disk)**

Run the app via `swift run Unison` (or launch the built `.app`), start a `.call`/`.listen` session, speak/produce at least one transcript line, then stop. Confirm a file appeared:

Run: `ls -la "$HOME/Library/Application Support/com.unison.app/meetings/"`
Expected: an `index.json` plus one `<uuid>.json`. Open `index.json` and confirm it lists the meeting. Quit and relaunch — the file persists.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonApp/Composition.swift
git commit -m "feat(history): wire FileMeetingStore into the composition root"
```

---

## Self-Review (completed by plan author)

**Spec coverage** (`docs/superpowers/specs/2026-06-24-meeting-history-design.md`):
- Data model (`MeetingRecord`, `MeetingSummary`, `TranscriptEntry: Codable + edited`, auto-title) → Tasks 1, 2. ✓
- Storage (per-meeting JSON + `index.json`, App Support, atomic, self-healing) → Tasks 5, 9. ✓
- Save flow (archive in `stop()` before idle, no clear, skip `.test`/empty/disabled, double-stop safe via `activeMode == nil`) → Task 8. ✓
- Size rotation (configurable limit, oldest-first, protect newest + pinned, no-limit, single-over-limit) → Tasks 3, 6, 9. ✓
- Pin (field + rotation exemption + list ordering) → Tasks 2, 3, 4. ✓ (Pin **UI** = Part 2.)
- Settings fields (`saveHistoryEnabled`, `historySizeLimitMB`, defaults, legacy decode) → Task 7. ✓
- Search (title/preview fast pass + lazy full-text) → Tasks 4, 6. ✓
- **Deferred to Part 2 (UI):** history window, master-detail list/detail editor (rename/delete-line/edit-text inline), menu "История…", hotkey, Settings "История" section + size/usage readout + "Очистить всю историю", app-launch behaviour beyond the `enforceSizeLimit()` sweep. Editing semantics are exercised at the store layer here (`rename`, `setPinned`, re-`save` of a mutated `entries`), so Part 2 is pure presentation.

**Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**Type consistency:** `MeetingStore` method names (`list/load/save/delete/rename/setPinned/search/totalSizeBytes/enforceSizeLimit/clearAll`) are identical across protocol (Task 4), `InMemoryMeetingStore` (Task 4), `FileMeetingStore` (Task 5), and call sites (Tasks 8, 9). `meetingsToEvict(_:limitMB:)`, `MeetingSummary(record:sizeBytes:)`, `MeetingRecord.currentSchemaVersion`, and `sortedForList()` are referenced consistently. The orchestrator init's new `meetingStore:` parameter is defaulted, so the only non-test call site needing an edit is `Composition` (Task 9). ✓

---

## Part 2 (UI) — next plan (roadmap, not yet detailed)

To be written as `docs/superpowers/plans/2026-06-24-meeting-history-part2-ui.md` against the working store from Part 1:

1. `MeetingHistoryViewModel` (`UnisonUI`) — load summaries, debounced search, selection, load selected record, mutations (rename / delete meeting / delete line / edit translated text / toggle pin / export), usage readout. Unit-testable against `InMemoryMeetingStore`.
2. `MeetingHistoryView` (`UnisonUI`) — master-detail: sidebar (search + pinned-first list) + detail (header with title+pencil, meta, export/pin/delete; transcript reusing `Bubble`/`BubbleGroupView` with inline edit + per-line delete); empty state.
3. `MeetingHistoryWindowController` (`UnisonApp`) — glass window modelled on `SettingsWindowController` + `GlassHostingViewController`.
4. Menu + hotkey — `onShowHistory` closure + "История…" item in `StatusItemController`; `HotkeyService` binding; wiring in `Composition`/`AppDelegate`.
5. Settings "История" section (`SettingsView`/`SettingsViewModel`) — save toggle, size-limit dropdown (25/50/100/250/500 МБ / Без лимита), "N встреч · X / Y МБ" readout, "Очистить всю историю" (confirm).
6. Optional `UNISON_FORCE_STATE=history-demo` for the screenshot harness.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-24-meeting-history-part1-persistence.md`. Two execution options:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
