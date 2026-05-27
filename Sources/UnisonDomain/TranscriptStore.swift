import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptStore {
    public private(set) var entries: [TranscriptEntry] = []
    public var currentLanguagePair: LanguagePair?
    /// Fires after each delta is folded into `entries`. The view-model
    /// uses this to bump the "live" typing-dots timer — without this
    /// hook, the live indicator that the design ships (and that the
    /// unit tests exercise) never appears in production because the
    /// orchestrator calls `apply()` directly and never touched the
    /// `setLive` / `extendLive` API. Composition wires the callback to
    /// `TranscriptViewModel.extendLive(entryId:)`.
    public var onDeltaApplied: (@MainActor (UUID) -> Void)?

    public init() {}

    public func apply(_ delta: TranscriptDelta) {
        if let idx = entries.firstIndex(where: { $0.id == delta.entryId }) {
            switch delta.kind {
            case .original:
                entries[idx].originalText = (entries[idx].originalText ?? "") + delta.text
            case .translated:
                entries[idx].translatedText += delta.text
                // A late-arriving translation chunk proves the entry's
                // translation was not lost after all — clear the at-risk
                // flag the pause/reconnect transition stamped on the
                // entry while it was mid-flight.
                entries[idx].translationAtRisk = false
            }
        } else {
            let targetLang: Language = {
                guard let pair = currentLanguagePair else { return .en }
                return delta.speaker == .me ? pair.peer : pair.mine
            }()
            let entry = TranscriptEntry(
                id: delta.entryId,
                speaker: delta.speaker,
                originalText: delta.kind == .original ? delta.text : nil,
                translatedText: delta.kind == .translated ? delta.text : "",
                sourceLanguage: nil,
                targetLanguage: targetLang,
                timestamp: Date()
            )
            entries.append(entry)
        }
        onDeltaApplied?(delta.entryId)
    }

    public func clear() { entries.removeAll() }

    /// Flag every currently-accumulating entry (one without a complete
    /// translation) as "at risk" of translation loss. Called by the
    /// orchestrator when it transitions to `.paused` / `.reconnecting`
    /// so the bubble view can later render a placeholder for entries
    /// that never received their translation. A late-arriving
    /// translation delta clears the flag in `apply(_:)`.
    public func markActiveEntriesAtRisk() {
        for idx in entries.indices where entries[idx].translatedText.isEmpty {
            entries[idx].translationAtRisk = true
        }
    }

    public func exportAsText() -> String {
        entries.map { e in
            let who = e.speaker == .me ? "Me" : "Peer"
            let orig = e.originalText.map { "  Original: \($0)\n" } ?? ""
            return "\(who):\n\(orig)  Translated: \(e.translatedText)"
        }.joined(separator: "\n\n")
    }
}
