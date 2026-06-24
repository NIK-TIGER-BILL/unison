# Meeting History — Part 2: UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the meeting archive a UI: a dedicated glass master-detail window (searchable list + read/edit transcript), a "История…" menu entry, and a Settings "История" section (save toggle, size limit, usage, clear-all).

**Architecture:** A `@MainActor @Observable` `MeetingHistoryViewModel` (pure logic over `MeetingStore`, fully unit-tested) drives `MeetingHistoryView` (SwiftUI `NavigationSplitView`). The detail pane renders **one row per `TranscriptEntry`** (not the split-bubble live renderer) because edit/delete are per-entry. `MeetingHistoryWindowController` hosts it in a glass `NSWindow` modelled on `SettingsWindowController`. Wiring goes through `Composition` → `AppDelegate` → `StatusItemController` exactly like the Diagnostic/Settings windows.

**Tech Stack:** Swift 6.2 toolchain / Swift 5 language mode, SwiftUI (macOS 26), swift-testing. `UnisonUI` cannot import AppKit — file export and window plumbing go through host closures. Tests run via `./scripts/test.sh --filter <name>`.

---

## Prerequisite

**Part 1 (`docs/superpowers/plans/2026-06-24-meeting-history-part1-persistence.md`) must be complete and merged.** This plan uses `MeetingStore`, `InMemoryMeetingStore`, `MeetingRecord`, `MeetingSummary`, `Composition.meetingStore`, and the `Settings.saveHistoryEnabled` / `historySizeLimitMB` fields it introduced. It also reuses the shared test builders in `Tests/UnisonDomainTests/MeetingTestSupport.swift`.

## File Structure

**New source files:**

| File | Responsibility |
| --- | --- |
| `Sources/UnisonUI/ViewModels/MeetingHistoryViewModel.swift` | List/search/selection + mutations (rename, delete meeting, delete line, edit text, pin, clear). Pure over `MeetingStore`. |
| `Sources/UnisonUI/Views/MeetingHistoryView.swift` | `NavigationSplitView` master-detail + sidebar rows + detail editor rows + empty state. |
| `Sources/UnisonApp/MeetingHistoryWindowController.swift` | Glass `NSWindow` host; bridges export to an `NSSavePanel`. |

**Modified source files:**

| File | Change |
| --- | --- |
| `Sources/UnisonDomain/MeetingRecord.swift` | `+ exportText()` plain-text rendering (for file export). |
| `Sources/UnisonUI/ViewModels/SettingsViewModel.swift` | `+ setSaveHistoryEnabled`, `+ setHistorySizeLimitMB`, optional `meetingStore`, `+ history usage readout + clearHistory`. |
| `Sources/UnisonUI/Views/SettingsView.swift` | `+ historySection` card. |
| `Sources/UnisonApp/StatusItemController.swift` | `+ onShowHistory` closure + "История…" menu item + `@objc menuShowHistory`. |
| `Sources/UnisonApp/Composition.swift` | Build `MeetingHistoryViewModel`; pass `meetingStore` into `SettingsViewModel`; expose the history VM. |
| `Sources/UnisonApp/AppDelegate.swift` | Create + show `MeetingHistoryWindowController`; wire `onShowHistory`; (optional) archive active session on terminate. |

**New test files (all in `Tests/UnisonDomainTests/`, which depends on `UnisonUI` + has `MockAudioDeviceRegistry` and the Part 1 `MeetingTestSupport`):**
`MeetingHistoryViewModelTests.swift`, `SettingsViewModelHistoryTests.swift`, `MeetingRecordExportTests.swift`.

---

## Task 1: `MeetingHistoryViewModel`

**Files:**
- Create: `Sources/UnisonUI/ViewModels/MeetingHistoryViewModel.swift`
- Test: `Tests/UnisonDomainTests/MeetingHistoryViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/MeetingHistoryViewModelTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter historyVM_`
Expected: FAIL — compile error (no `MeetingHistoryViewModel`).

- [ ] **Step 3: Implement the view model**

Create `Sources/UnisonUI/ViewModels/MeetingHistoryViewModel.swift`:

```swift
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
        if selectedID == id { selectedID = nil }
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
        selectedID = nil
        reload()
    }

    public var isEmptyArchive: Bool { summaries.isEmpty && query.isEmpty }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter historyVM_`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/ViewModels/MeetingHistoryViewModel.swift Tests/UnisonDomainTests/MeetingHistoryViewModelTests.swift
git commit -m "feat(history): MeetingHistoryViewModel — list/search/edit over the store"
```

---

## Task 2: `MeetingRecord.exportText()` (for file export)

**Files:**
- Modify: `Sources/UnisonDomain/MeetingRecord.swift`
- Test: `Tests/UnisonDomainTests/MeetingRecordExportTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/MeetingRecordExportTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain

@Test func meetingRecord_exportText_includesTitleAndLines() {
    let rec = MeetingRecord(
        id: UUID(), title: "Планёрка",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_060),
        mode: .call, languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: [
            sampleEntry(.peer, "Привет"),
            sampleEntry(.me, "Здравствуйте")
        ])
    let text = rec.exportText()
    #expect(text.contains("Планёрка"))
    #expect(text.contains("Привет"))
    #expect(text.contains("Здравствуйте"))
}

@Test func meetingRecord_exportText_usesDisplayTitleWhenUntitled() {
    let rec = MeetingRecord(
        id: UUID(), title: nil,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_060),
        mode: .listen, languagePair: LanguagePair(mine: .ru, peer: .en),
        entries: [sampleEntry()])
    #expect(rec.exportText().hasPrefix("Прослушивание · "))
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter meetingRecord_exportText_`
Expected: FAIL — compile error (no `exportText`).

- [ ] **Step 3: Implement `exportText()`**

Add to `MeetingRecord` in `Sources/UnisonDomain/MeetingRecord.swift` (after `displayTitle`):

```swift
    /// Plain-text rendering for file export. Speaker-labelled, original +
    /// translated per line.
    public func exportText() -> String {
        var lines = [displayTitle, ""]
        for e in entries {
            let who = e.speaker == .me ? "Я" : "Собеседник"
            lines.append(who + ":")
            if let original = e.originalText, !original.isEmpty {
                lines.append("  оригинал: " + original)
            }
            lines.append("  перевод: " + e.translatedText)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter meetingRecord_exportText_`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/MeetingRecord.swift Tests/UnisonDomainTests/MeetingRecordExportTests.swift
git commit -m "feat(history): MeetingRecord.exportText() for file export"
```

---

## Task 3: `MeetingHistoryView` (master-detail UI)

**Files:**
- Create: `Sources/UnisonUI/Views/MeetingHistoryView.swift`

(SwiftUI view; the logic it calls is already tested in Task 1. Verification = build + a manual run. An optional snapshot test is noted at the end.)

- [ ] **Step 1: Implement the view**

Create `Sources/UnisonUI/Views/MeetingHistoryView.swift`:

```swift
import SwiftUI
import UnisonDomain

/// Meeting archive window: searchable list (left) + read/edit transcript
/// (right). `UnisonUI` can't import AppKit, so file export is delegated to
/// the host via `onExport`.
public struct MeetingHistoryView: View {
    @Bindable var vm: MeetingHistoryViewModel
    let onExport: (MeetingRecord) -> Void

    public init(
        vm: MeetingHistoryViewModel,
        onExport: @escaping (MeetingRecord) -> Void = { _ in }
    ) {
        self.vm = vm
        self.onExport = onExport
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 460)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Поиск по встречам", text: $vm.query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            if vm.isEmptyArchive {
                Spacer()
                Text("Пока нет сохранённых встреч")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                Spacer()
            } else {
                List(selection: $vm.selectedID) {
                    ForEach(vm.summaries) { s in
                        MeetingRow(summary: s)
                            .tag(s.id)
                            .contextMenu { rowMenu(for: s) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func rowMenu(for s: MeetingSummary) -> some View {
        Button(s.pinned ? "Открепить" : "Закрепить") { vm.togglePin(s.id) }
        Button("Удалить", role: .destructive) { vm.deleteMeeting(s.id) }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if let record = vm.selectedRecord {
            MeetingDetailView(vm: vm, record: record, onExport: onExport)
        } else {
            Text("Выберите встречу")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Sidebar row

private struct MeetingRow: View {
    let summary: MeetingSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if summary.pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(summary.displayTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        let pair = "\(summary.languagePair.mine.rawValue.uppercased()) → \(summary.languagePair.peer.rawValue.uppercased())"
        let mins = max(1, summary.durationSeconds / 60)
        return "\(pair) · \(mins) мин · \(summary.lineCount) реплик"
    }
}

// MARK: - Detail (header + transcript)

private struct MeetingDetailView: View {
    @Bindable var vm: MeetingHistoryViewModel
    let record: MeetingRecord
    let onExport: (MeetingRecord) -> Void

    @SwiftUI.State private var isRenaming = false
    @SwiftUI.State private var draftTitle = ""
    @SwiftUI.State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(record.entries) { entry in
                        MeetingLineRow(
                            entry: entry,
                            onEdit: { newText in vm.editLine(entry.id, newText: newText) },
                            onDelete: { vm.deleteLine(entry.id) }
                        )
                    }
                }
                .padding(16)
            }
        }
        .confirmationDialog("Удалить встречу?", isPresented: $showDeleteConfirm) {
            Button("Удалить", role: .destructive) { vm.deleteMeeting(record.id) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isRenaming {
                    TextField("Название", text: $draftTitle)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                        .onSubmit { commitRename() }
                    Button("Готово") { commitRename() }
                } else {
                    Text(record.displayTitle).font(.system(size: 16, weight: .medium))
                    Button { draftTitle = record.title ?? ""; isRenaming = true } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)
                    .help("Переименовать")
                }
                Spacer()
                Button { vm.togglePin(record.id) } label: {
                    Image(systemName: record.pinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(record.pinned ? "Открепить" : "Закрепить")
                Button { onExport(record) } label: { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).help("Экспортировать")
                Button { showDeleteConfirm = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Удалить встречу")
            }
            Text(metaLine)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var metaLine: String {
        let pair = "\(record.languagePair.mine.rawValue.uppercased()) → \(record.languagePair.peer.rawValue.uppercased())"
        let mins = max(1, record.durationSeconds / 60)
        let mode = record.mode == .listen ? "Прослушивание" : "Звонок"
        return "\(mode) · \(mins) мин · \(pair)"
    }

    private func commitRename() {
        vm.rename(record.id, to: draftTitle)
        isRenaming = false
    }
}

// MARK: - One transcript line (read + inline edit)

private struct MeetingLineRow: View {
    let entry: TranscriptEntry
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    @SwiftUI.State private var isEditing = false
    @SwiftUI.State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.speaker == .me ? "Я" : "Собеседник")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(entry.speaker == .me ? Color.teal : Color.purple)
                if entry.edited {
                    Text("изменено").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
                if !isEditing {
                    Button { draft = entry.translatedText; isEditing = true } label: {
                        Image(systemName: "pencil")
                    }.buttonStyle(.borderless).help("Изменить реплику")
                    Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Удалить реплику")
                }
            }
            if isEditing {
                TextField("Текст реплики", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Готово") { onEdit(draft); isEditing = false }
                    Button("Отмена") { isEditing = false }
                }
            } else {
                Text(entry.translatedText)
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                if let original = entry.originalText, !original.isEmpty {
                    Text(original)
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(UnisonColors.whiteAlpha(0.04))
        )
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors. (If `UnisonColors.whiteAlpha` is unavailable in this context, replace the background `.fill(...)` with `.fill(Color.primary.opacity(0.04))` — it is used the same way in `SettingsView.swift`.)

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonUI/Views/MeetingHistoryView.swift
git commit -m "feat(history): master-detail MeetingHistoryView with inline line editing"
```

---

## Task 4: `MeetingHistoryWindowController`

**Files:**
- Create: `Sources/UnisonApp/MeetingHistoryWindowController.swift`

- [ ] **Step 1: Implement the window controller**

Create `Sources/UnisonApp/MeetingHistoryWindowController.swift` (modelled on `SettingsWindowController`):

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import UnisonDomain
import UnisonUI

/// Hosts the meeting-archive `NSWindow`. Standard `.titled` glass chrome
/// like Settings. Bridges `MeetingHistoryView`'s export closure into an
/// `NSSavePanel` (UnisonUI can't import AppKit).
@MainActor
public final class MeetingHistoryWindowController {
    private var window: NSWindow?
    private let viewModel: MeetingHistoryViewModel

    public init(viewModel: MeetingHistoryViewModel) {
        self.viewModel = viewModel
    }

    public func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Unison · История"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.minSize = NSSize(width: 720, height: 460)

            let root = MeetingHistoryView(
                vm: viewModel,
                onExport: { [weak self] record in self?.exportToFile(record) }
            )
            w.contentViewController = GlassHostingViewController(
                rootView: root,
                style: .regular,
                cornerRadius: 10
            )
            w.setContentSize(NSSize(width: 820, height: 560))
            w.center()
            window = w
        }
        // Refresh the list each show in case sessions ended (or rotation
        // ran) while the window was closed.
        viewModel.reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func exportToFile(_ record: MeetingRecord) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = record.displayTitle + ".txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? record.exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonApp/MeetingHistoryWindowController.swift
git commit -m "feat(history): glass window controller for the meeting archive"
```

---

## Task 5: Settings "История" section

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/SettingsViewModel.swift`
- Modify: `Sources/UnisonUI/Views/SettingsView.swift`
- Test: `Tests/UnisonDomainTests/SettingsViewModelHistoryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/UnisonDomainTests/SettingsViewModelHistoryTests.swift`:

```swift
import Foundation
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
@Test func settingsVM_setSaveHistoryEnabled_persistsViaOnChange() {
    var saved: Settings?
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { saved = $0 })
    vm.setSaveHistoryEnabled(false)
    #expect(vm.settings.saveHistoryEnabled == false)
    #expect(saved?.saveHistoryEnabled == false)
}

@MainActor
@Test func settingsVM_setHistorySizeLimit_persistsViaOnChange() {
    var saved: Settings?
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { saved = $0 })
    vm.setHistorySizeLimitMB(250)
    #expect(vm.settings.historySizeLimitMB == 250)
    #expect(saved?.historySizeLimitMB == 250)
}

@MainActor
@Test func settingsVM_historyUsage_readsStore() {
    let store = InMemoryMeetingStore()
    store.save(recordAt(daysAgo: 1, entries: [sampleEntry()]))
    store.save(recordAt(daysAgo: 2, entries: [sampleEntry()]))
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { _ in }, meetingStore: store)
    vm.refreshHistoryUsage()
    #expect(vm.historyMeetingCount == 2)
    #expect(vm.historyTotalBytes > 0)
}

@MainActor
@Test func settingsVM_clearHistory_emptiesStoreAndUsage() {
    let store = InMemoryMeetingStore()
    store.save(recordAt(daysAgo: 1, entries: [sampleEntry()]))
    let vm = SettingsViewModel(initial: .default, deviceRegistry: MockAudioDeviceRegistry(),
                               onChange: { _ in }, meetingStore: store)
    vm.clearHistory()
    #expect(vm.historyMeetingCount == 0)
    #expect(store.list().isEmpty)
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter settingsVM_setSaveHistory settingsVM_setHistorySize settingsVM_historyUsage settingsVM_clearHistory`
Expected: FAIL — compile error (no `meetingStore:` parameter; no `setSaveHistoryEnabled` / `setHistorySizeLimitMB` / `refreshHistoryUsage` / `historyMeetingCount` / `historyTotalBytes` / `clearHistory`).

- [ ] **Step 3: Extend `SettingsViewModel`**

Add the optional dependency. In the "Optional dependencies" group (around line 32) add:

```swift
    private let meetingStore: (any MeetingStore)?
```

Add stored usage state near `lastSavedAt`:

```swift
    /// History archive usage, refreshed on demand (the store isn't
    /// Observable). The window controller calls `refreshHistoryUsage()`
    /// each `show()`.
    public private(set) var historyMeetingCount: Int = 0
    public private(set) var historyTotalBytes: Int = 0
```

Add the init parameter (append to the parameter list, defaulted) and assignment + initial refresh. Change the init signature tail:

```swift
        hotkeyStore: HotkeyStorage? = nil,
        togglesStore: ToggleStorage? = nil,
        meetingStore: (any MeetingStore)? = nil
    ) {
```
```swift
        self.hotkeyStore = hotkeyStore
        self.togglesStore = togglesStore
        self.meetingStore = meetingStore
```

At the end of `init` (after `refreshDeviceList()`), add:

```swift
        refreshHistoryUsage()
```

Add the mutators + usage methods (place them next to the other mutators, before `// MARK: - Private`):

```swift
    public func setSaveHistoryEnabled(_ on: Bool) {
        settings.saveHistoryEnabled = on
        emitChange()
    }

    public func setHistorySizeLimitMB(_ mb: Int) {
        settings.historySizeLimitMB = mb
        emitChange()
    }

    /// Re-read archive usage from the store (count + total bytes).
    public func refreshHistoryUsage() {
        historyMeetingCount = meetingStore?.list().count ?? 0
        historyTotalBytes = meetingStore?.totalSizeBytes() ?? 0
    }

    public func clearHistory() {
        meetingStore?.clearAll()
        refreshHistoryUsage()
        bumpSavedTimestamp()
    }
```

Add `import` is unnecessary — `MeetingStore` is in `UnisonDomain`, already imported by the file.

- [ ] **Step 4: Run the test, verify it passes**

Run: `./scripts/test.sh --filter settingsVM_setSaveHistory settingsVM_setHistorySize settingsVM_historyUsage settingsVM_clearHistory`
Expected: PASS (4 tests). Also run `./scripts/test.sh --filter SettingsViewModelTests` to confirm no regression.

- [ ] **Step 5: Add the `historySection` to `SettingsView`**

In `Sources/UnisonUI/Views/SettingsView.swift`, add `historySection` to the body's `VStack` (after `behaviorSection`, before `aboutSection`):

```swift
                behaviorSection
                historySection
                aboutSection
```

Add the section + size presets (place near the other section vars, e.g. after `behaviorSection`):

```swift
    private static let historySizePresets: [Int] = [25, 50, 100, 250, 500, 0]   // 0 = без лимита

    private func sizeLimitLabel(_ mb: Int) -> String { mb == 0 ? "Без лимита" : "\(mb) МБ" }

    private var historySection: some View {
        card(title: "История") {
            LabeledContent("Сохранять историю встреч") {
                Toggle("Сохранять историю встреч", isOn: Binding(
                    get: { vm.settings.saveHistoryEnabled },
                    set: { vm.setSaveHistoryEnabled($0) }
                ))
                .labelsHidden()
            }
            LabeledContent("Лимит размера") {
                Picker("Лимит размера", selection: Binding(
                    get: { vm.settings.historySizeLimitMB },
                    set: { vm.setHistorySizeLimitMB($0) }
                )) {
                    ForEach(Self.historySizePresets, id: \.self) { mb in
                        Text(sizeLimitLabel(mb)).tag(mb)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            LabeledContent("Сейчас в архиве") {
                Text("\(vm.historyMeetingCount) встреч · \(String(format: "%.1f", Double(vm.historyTotalBytes) / (1024 * 1024))) МБ")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            LabeledContent {
                InlineButton(
                    "Очистить всю историю",
                    icon: Image(systemName: "trash"),
                    variant: .base,
                    isLoading: false,
                    action: { vm.clearHistory() }
                )
            } label: {
                Text("Удалить все сохранённые встречи")
            }
        }
    }
```

(If `InlineButton`'s signature differs, mirror the exact call used in `blackHoleSection` above — it constructs `InlineButton("Переустановить", icon:variant:isLoading:action:)`.)

- [ ] **Step 6: Build**

Run: `swift build`
Expected: builds with no errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/UnisonUI/ViewModels/SettingsViewModel.swift Sources/UnisonUI/Views/SettingsView.swift Tests/UnisonDomainTests/SettingsViewModelHistoryTests.swift
git commit -m "feat(history): Settings section — save toggle, size limit, usage, clear-all"
```

---

## Task 6: Wire the window + menu (`Composition`, `AppDelegate`, `StatusItemController`)

**Files:**
- Modify: `Sources/UnisonApp/Composition.swift`
- Modify: `Sources/UnisonApp/StatusItemController.swift`
- Modify: `Sources/UnisonApp/AppDelegate.swift`

- [ ] **Step 1: Expose a history VM from `Composition` + pass the store to Settings**

In `Sources/UnisonApp/Composition.swift`, add the public property (after `public let meetingStore: any MeetingStore` from Part 1):

```swift
    public let meetingHistoryVM: MeetingHistoryViewModel
```

Pass `meetingStore` into the `SettingsViewModel(...)` construction (add the argument to the existing call, around line 189):

```swift
            hotkeyStore: UserDefaultsHotkeyStorage(),
            togglesStore: UserDefaultsToggleStorage(),
            meetingStore: meetingStore
        )
```

Construct the history VM after `meetingStore` exists (e.g. right after `self.transcriptVM = ...`, before `wireCrossSurfaceSync()`):

```swift
        self.meetingHistoryVM = MeetingHistoryViewModel(store: meetingStore)
```

- [ ] **Step 2: Add `onShowHistory` to `StatusItemController`**

In `Sources/UnisonApp/StatusItemController.swift`:

(a) Add the closure property (after `public var onShowDiagnostic`, line 29):

```swift
    public var onShowHistory: (() -> Void)?
```

(b) Add an init parameter (after `onShowDiagnostic` param, line 58) and assign it:

```swift
        onShowDiagnostic: @escaping () -> Void = {},
        onShowHistory: @escaping () -> Void = {},
```
```swift
        self.onShowDiagnostic = onShowDiagnostic
        self.onShowHistory = onShowHistory
```

(c) Add the menu item. In `presentContextMenu(...)`, after the "Show Transcript" item is added (`menu.addItem(showTranscript)`, around line 281), insert:

```swift
        let history = NSMenuItem(
            title: "История…",
            action: #selector(menuShowHistory(_:)),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)
```

(d) Add the action (next to `menuShowDiagnostic`, around line 341):

```swift
    @objc private func menuShowHistory(_ sender: NSMenuItem) { onShowHistory?() }
```

- [ ] **Step 3: Create + wire the window in `AppDelegate`**

In `Sources/UnisonApp/AppDelegate.swift`:

(a) Add the stored controller (after `public var diagnosticWindow: DiagnosticWindowController!`, line 19):

```swift
    public var historyWindow: MeetingHistoryWindowController!
```

(b) Construct it (after `diagnosticWindow = DiagnosticWindowController(...)`, around line 96):

```swift
        historyWindow = MeetingHistoryWindowController(viewModel: composition.meetingHistoryVM)
```

(c) Pass `onShowHistory` into the `StatusItemController(...)` construction (add the argument after `onShowDiagnostic:`, around line 112):

```swift
            onShowDiagnostic: { [weak self] in
                self?.diagnosticWindow.show()
            },
            onShowHistory: { [weak self] in
                self?.historyWindow.show()
            },
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build`
Expected: builds with no errors.

Run: `./scripts/test.sh`
Expected: entire suite PASS.

- [ ] **Step 5: Manual smoke check**

Launch the app (`swift run Unison` or the built `.app`). Right-click the menubar icon → "История…" opens the window. Run a short `.call`/`.listen` session, stop it, reopen "История…" → the meeting appears in the list. Select it → transcript renders. Edit a line → "Готово" → reopen the window → the edit persisted. Rename, pin (it floats to top), delete (with confirm). Open Settings → "История" section shows count + size; "Очистить всю историю" empties it.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonApp/Composition.swift Sources/UnisonApp/StatusItemController.swift Sources/UnisonApp/AppDelegate.swift
git commit -m "feat(history): wire archive window + История menu entry"
```

---

## Task 7 (optional): Archive the active session on quit

Quitting mid-session does not archive it: `applicationWillTerminate` deliberately avoids `await orchestrator.stop()` (it would deadlock the main actor), so the Part 1 archive hook never fires for a quit-during-session. This task adds a **synchronous** archive path.

**Files:**
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`
- Modify: `Sources/UnisonApp/AppDelegate.swift`
- Test: `Tests/UnisonDomainTests/OrchestratorArchiveTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `Tests/UnisonDomainTests/OrchestratorArchiveTests.swift`:

```swift
@MainActor
@Test func archiveActiveSession_savesWhenTranslating() async {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    // Drive into a translating state without the audio stack: the public
    // archive hook reads state.activeMode / sessionStartedAt.
    orch.forceStateForTesting(.translating(mode: .call, startedAt: Date(timeIntervalSince1970: 1000)))
    orch.archiveActiveSession()
    #expect(store.list().count == 1)
}

@MainActor
@Test func archiveActiveSession_noopWhenIdle() {
    let store = InMemoryMeetingStore()
    let orch = makeOrchestrator(store: store)
    seedOneEntry(orch)
    orch.archiveActiveSession()        // state is .idle
    #expect(store.list().isEmpty)
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `./scripts/test.sh --filter archiveActiveSession_`
Expected: FAIL — no `archiveActiveSession` / `forceStateForTesting`.

- [ ] **Step 3: Add the public hook + a test seam**

In `Sources/UnisonDomain/TranslationOrchestrator.swift`, add (next to `archiveSession`):

```swift
    /// Synchronous archive of the currently-active session. Safe to call
    /// from `applicationWillTerminate` (no `await`). No-op when idle.
    public func archiveActiveSession() {
        archiveSession(mode: state.activeMode, startedAt: state.sessionStartedAt,
                       enabled: currentSettings.saveHistoryEnabled)
    }

    /// Test seam: force `state` for unit tests that can't run the audio
    /// stack. Not used in production.
    func forceStateForTesting(_ s: SessionState) { state = s }
```

- [ ] **Step 4: Call it from `applicationWillTerminate`**

In `Sources/UnisonApp/AppDelegate.swift`, inside `applicationWillTerminate(_:)`, before the audio teardown (`composition.virtualMicPlayer.stop()`), add:

```swift
        // Archive an active-at-quit session synchronously (the async
        // orchestrator.stop() path is intentionally skipped here — see
        // below — so the Part 1 stop() archive hook never fires on quit).
        composition.orchestrator.archiveActiveSession()
```

- [ ] **Step 5: Run the test + build**

Run: `./scripts/test.sh --filter archiveActiveSession_`
Expected: PASS (2 tests).

Run: `swift build`
Expected: builds.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/TranslationOrchestrator.swift Sources/UnisonApp/AppDelegate.swift Tests/UnisonDomainTests/OrchestratorArchiveTests.swift
git commit -m "feat(history): archive active session on app quit"
```

---

## Task 8 (optional): Hotkey + `history-demo` force state

Deferrable polish; each is independent.

- **Global hotkey "Показать историю".** Higher surface than it looks: add a `HotkeyKind.showHistory` case, extend `HotkeyService.updateHotkeys` and the recording/persistence plumbing, add a Settings "Хоткеи" row, and a `defaultShowHistory` combo. Recommended only if the user actively wants a keyboard shortcut — the menu entry covers access otherwise. **Confirm scope before implementing.**
- **`UNISON_FORCE_STATE=history-demo`.** Add the case to `UnisonForceState`, seed a couple of `MeetingRecord`s into `composition.meetingStore` in `Composition.init`, and open the window in `AppDelegate.applyForceStateOverrides()`. Lets the Tart screenshot harness capture the archive surface.

---

## Self-Review (completed by plan author)

**Spec coverage** (against `2026-06-24-meeting-history-design.md` items not built in Part 1):
- History window, master-detail, search → Tasks 1, 3, 4 (window). ✓
- Editing: rename / delete line / edit translated text, pin → Task 1 (logic, tested) + Task 3 (UI). ✓
- Menu "История…" → Task 6. ✓ Hotkey → Task 8 (optional, scope-flagged per the YAGNI lean). ⚠ by design.
- Settings "История": save toggle, size dropdown (25/50/100/250/500 / Без лимита), usage readout, "Очистить всю историю" → Task 5. ✓
- Export (reuse text rendering) → Task 2 (`exportText`) + Task 4 (`NSSavePanel`). ✓
- Empty state → Task 3. ✓
- Active-session-at-quit archiving (gap noted in the spec/Part 1) → Task 7 (optional). ✓

**Placeholder scan:** No TBD/TODO. Two explicit fallbacks are given as conditional instructions (`UnisonColors.whiteAlpha` → `Color.primary.opacity`; `InlineButton` signature → mirror `blackHoleSection`) rather than placeholders — both name the exact replacement and the in-repo reference. ✓

**Type consistency:** `MeetingHistoryViewModel` API (`summaries`, `query`, `selectedID`, `selectedRecord`, `reload`, `rename`, `togglePin`, `deleteMeeting`, `deleteLine`, `editLine`, `clearAll`, `isEmptyArchive`) is consistent between Task 1 (definition), Task 3 (view), and Task 6 (composition). `SettingsViewModel` additions (`setSaveHistoryEnabled`, `setHistorySizeLimitMB`, `refreshHistoryUsage`, `historyMeetingCount`, `historyTotalBytes`, `clearHistory`, `meetingStore:` param) match between Task 5 and the `SettingsView`/`Composition` call sites. `onShowHistory` is consistent across `StatusItemController` (Task 2-of-6) and `AppDelegate` (Task 3-of-6). `MeetingRecord.exportText()` is defined in Task 2 and consumed in Task 4. ✓

**Note on a design deviation (intentional):** the detail pane renders **one row per `TranscriptEntry`** rather than reusing the live `Bubble`/`TranscriptGrouping` split renderer. Reason: edit/delete operate per entry, and the grouping renderer splits one entry into multiple bubbles — mixing the two would make per-entry mutation ambiguous. The read experience is equivalent (speaker label, translation primary, original secondary); only the implementation mechanism differs from the spec's "reuse Bubble" wording.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-24-meeting-history-part2-ui.md`. Recommend executing **Part 1 first**, then this. Two execution options for each:

1. **Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks.
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach (and shall I start with Part 1)?
