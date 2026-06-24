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
                .id(record.id)
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
        return "\(pair) · \(mins) мин · \(summary.lineCount) \(pluralReplicas(summary.lineCount))"
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

/// Russian plural form for "реплика" (line/utterance).
private func pluralReplicas(_ n: Int) -> String {
    let mod10 = n % 10
    let mod100 = n % 100
    if mod10 == 1 && mod100 != 11 { return "реплика" }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "реплики" }
    return "реплик"
}
