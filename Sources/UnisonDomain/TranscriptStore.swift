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

    public func exportAsText() -> String {
        entries.map { e in
            let who = e.speaker == .me ? "Me" : "Peer"
            let orig = e.originalText.map { "  Original: \($0)\n" } ?? ""
            return "\(who):\n\(orig)  Translated: \(e.translatedText)"
        }.joined(separator: "\n\n")
    }
}
