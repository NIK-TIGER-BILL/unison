import Foundation
import Observation

@MainActor
@Observable
public final class TranscriptStore {
    public private(set) var entries: [TranscriptEntry] = []
    public var currentLanguagePair: LanguagePair?

    private let clock: Clock

    /// Maps a stream's reused utterance id → the live entry now feeding it.
    /// Each translation stream mints ONE id per utterance and rotates it on
    /// its own signals alone (OpenAI: a 5 s input-gap or the server's
    /// `session.output_transcript.done`; Gemini: an input pause ≥ 1.5 s). A
    /// stream cannot see the OTHER speaker take a turn, so when one side pauses
    /// shorter than its rotation gap while the other speaks and then resumes,
    /// its stream reuses a now-stale id for a genuinely new utterance. `apply`
    /// forks a fresh entry in that case and records the mapping here so the
    /// rest of that utterance's deltas keep accumulating into the fork. Reset
    /// by `clear()`.
    private var forkedEntryId: [UUID: UUID] = [:]

    /// Wall-clock of the most recent `.original` (source-transcript) delta
    /// per live entry. The handoff check measures quiet-ness from THIS, not
    /// from `lastActivityAt`: a translation of the previous utterance can lag
    /// 5+ s and land — bumping `lastActivityAt` — just before the speaker
    /// resumes; counting it would mask the handoff and retro-append the new
    /// utterance into the buried bubble (the very bug the fork prevents).
    /// Reset by `clear()`.
    private var lastSourceDeltaAtByEntry: [UUID: Date] = [:]

    /// A reused utterance id forks a new bubble only once the matched entry
    /// has had no SOURCE delta for at least this long AND the other speaker
    /// has spoken since. That combination is a real conversational handoff;
    /// two people talking over each other keep the same id streaming with no
    /// input gap, and must NOT fragment into a fresh bubble on every
    /// alternation. Kept shorter than either stream's same-speaker turn-gap
    /// (5 s OpenAI, 1.5 s Gemini) because a cross-speaker handoff is a stronger
    /// boundary than a lone pause. A whole handoff compressed under this
    /// threshold (sub-second ping-pong) is intentionally left merged rather
    /// than risk fragmenting fast overlap.
    private static let crossSpeakerHandoffGapSeconds: TimeInterval = 1.0

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
    }

    public func apply(_ delta: TranscriptDelta) {
        // Resolve through any prior fork so the tail of a forked utterance
        // keeps accumulating into its new entry rather than re-matching the
        // stale original.
        let liveId = forkedEntryId[delta.entryId] ?? delta.entryId
        if let idx = entries.firstIndex(where: { $0.id == liveId }) {
            // Turn-aware fork. The stream reuses one id per utterance but is
            // blind to the other speaker. If a new utterance's source
            // transcript (`.original`) reuses an id whose entry the other
            // speaker has since spoken past — and that entry has gone quiet —
            // the stream missed a turn boundary it had no way to observe.
            // Start a fresh entry so the resumed speech lands in a NEW bubble
            // after the interjection instead of retro-appending into the
            // buried one (which renders above the interjection).
            //
            // Gated to `.original` (the start-of-utterance signal) so a
            // *translation* chunk that merely lagged behind its own source —
            // a normal 5+ s IN→OUT delay inside one turn — is never mistaken
            // for a new turn and split away from the original it belongs to.
            // Quiet-ness is measured from the last SOURCE delta (not any
            // delta) so a lagging translation can't mask the handoff.
            let lastSourceAt = lastSourceDeltaAtByEntry[liveId] ?? entries[idx].timestamp
            if delta.kind == .original,
               !delta.text.isEmpty,
               otherSpeakerSpokeAfter(idx, speaker: delta.speaker),
               clock.now().timeIntervalSince(lastSourceAt) >= Self.crossSpeakerHandoffGapSeconds {
                let forkId = UUID()
                forkedEntryId[delta.entryId] = forkId
                appendEntry(id: forkId, delta: delta)
                return
            }
            switch delta.kind {
            case .original:
                entries[idx].originalText = (entries[idx].originalText ?? "") + delta.text
                lastSourceDeltaAtByEntry[liveId] = clock.now()
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
            entries[idx].lastActivityAt = clock.now()
        } else {
            // Don't mint an entry for an empty delta with an unknown
            // entryId — an empty `.translated` handshake/reconstruct
            // chunk (see the at-risk note above) arriving first for a
            // fresh id would otherwise create a permanently blank
            // ghost bubble that nothing ever removes.
            guard !delta.text.isEmpty else { return }
            appendEntry(id: delta.entryId, delta: delta)
        }
    }

    /// True when at least one entry after `idx` belongs to a different
    /// speaker — i.e. the conversation handed off to the other side after
    /// the entry at `idx` last grew.
    private func otherSpeakerSpokeAfter(_ idx: Int, speaker: Speaker) -> Bool {
        entries[(idx + 1)...].contains { $0.speaker != speaker }
    }

    /// Append a fresh entry for `delta` under the given id.
    private func appendEntry(id: UUID, delta: TranscriptDelta) {
        let targetLang: Language = {
            guard let pair = currentLanguagePair else { return .en }
            return delta.speaker == .me ? pair.peer : pair.mine
        }()
        entries.append(TranscriptEntry(
            id: id,
            speaker: delta.speaker,
            originalText: delta.kind == .original ? delta.text : nil,
            translatedText: delta.kind == .translated ? delta.text : "",
            sourceLanguage: nil,
            targetLanguage: targetLang,
            timestamp: clock.now()
        ))
        if delta.kind == .original {
            lastSourceDeltaAtByEntry[id] = clock.now()
        }
    }

    public func clear() {
        entries.removeAll()
        forkedEntryId.removeAll()
        lastSourceDeltaAtByEntry.removeAll()
    }

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
