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

    static func displayTitle(title: String?, mode: SessionMode, startedAt: Date) -> String {
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return title }
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
    public let title: String?
    public let startedAt: Date
    public let durationSeconds: Int
    public let mode: SessionMode
    public let languagePair: LanguagePair
    public let lineCount: Int
    public let preview: String
    public let pinned: Bool
    public let sizeBytes: Int

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
