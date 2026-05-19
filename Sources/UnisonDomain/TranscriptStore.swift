import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptStore {
    public private(set) var entries: [TranscriptEntry] = []

    public init() {}

    public func apply(_ delta: TranscriptDelta) {
        if let idx = entries.firstIndex(where: { $0.id == delta.entryId }) {
            switch delta.kind {
            case .original:
                entries[idx].originalText = (entries[idx].originalText ?? "") + delta.text
            case .translated:
                entries[idx].translatedText = entries[idx].translatedText + delta.text
            }
        } else {
            let entry = TranscriptEntry(
                id: delta.entryId,
                speaker: delta.speaker,
                originalText: delta.kind == .original ? delta.text : nil,
                translatedText: delta.kind == .translated ? delta.text : "",
                sourceLanguage: nil,
                targetLanguage: .en,
                timestamp: Date()
            )
            entries.append(entry)
        }
    }

    public func clear() { entries.removeAll() }

    public func exportAsText() -> String {
        entries.map { e in
            let who = e.speaker == .me ? "Me" : "Peer"
            let orig = e.originalText.map { "  Original: \($0)\n" } ?? ""
            return "\(who):\n\(orig)  Translated: \(e.translatedText)"
        }.joined(separator: "\n\n")
    }
}
