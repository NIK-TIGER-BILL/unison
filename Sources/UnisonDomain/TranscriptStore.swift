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
                //
                // BUT: only clear when the delta carries actual text.
                // An empty `.translated` delta (handshake chunk before
                // close, partial reconstruct) shouldn't suppress the
                // at-risk indicator without delivering content
                // (review finding #14).
                if !delta.text.isEmpty {
                    entries[idx].translationAtRisk = false
                }
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

    /// Flag entries whose translation never arrived as "at risk" of
    /// translation loss. Called by the orchestrator when it transitions
    /// to `.paused` / `.reconnecting`; a late NON-empty translation
    /// delta clears the flag in `apply(_:)`.
    ///
    /// `speaker` scopes the operation: pass `.me` or `.peer` to flag
    /// only that side's in-flight entries (used by single-stream
    /// failure paths so a peer-stream WS drop doesn't decorate the
    /// healthy me-stream's in-flight bubble with a placeholder).
    /// Pass `nil` to flag every in-flight entry — appropriate for
    /// global teardowns like network pause where both streams are
    /// torn down at once (iter-3 review finding).
    ///
    /// We only flag entries where `translatedText` is empty — those
    /// are the unambiguous "nothing arrived" case the placeholder UI
    /// is built for. Entries with a partial translation (some deltas
    /// arrived before the drop) keep their partial text on screen
    /// rather than being wiped out with a placeholder; the partial
    /// is still useful context for the user even if the tail is
    /// missing. (Earlier iter-1 fix tried to flag partials too but
    /// the placeholder UI doesn't have a way to render alongside
    /// existing text without obscuring it — iter-2 review #3/#9.)
    public func markActiveEntriesAtRisk(speaker: Speaker? = nil) {
        for idx in entries.indices where entries[idx].translatedText.isEmpty {
            if let speaker, entries[idx].speaker != speaker { continue }
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
