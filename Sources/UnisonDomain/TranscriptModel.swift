import Foundation
import Observation

public struct TranscriptBubble: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let source: String
    public let translation: String
    public let translationLost: Bool
    /// When the utterance's turn STARTED. Stable across the live→frozen
    /// transition, so bubbles order by this and never change place.
    public let startedAt: Date
    /// When the bubble last had activity (freeze instant for frozen, last delta
    /// for live). Drives the recency-window expiry, NOT ordering.
    public let committedAt: Date
    public let isLive: Bool
}

/// Turns a speaker's streamed source+translation deltas into transcript
/// bubbles, ONE per sentence, sealed PROACTIVELY: the moment a sentence is
/// complete in BOTH the source and the (lagging) translation, it freezes into
/// its own immutable bubble — no accumulate-then-split, so a frozen bubble is
/// never re-partitioned (no "jump"). Only the still-forming tail is live.
///
/// Sentences pair by index WITHIN a turn; a turn ends (and the index resets) on
/// a long pause (`pauseSeconds`) or when the OTHER speaker interrupts — so a
/// rare in-turn sentence mismatch (the translation merging/splitting differently
/// than the source) is bounded to one turn and self-heals at the next reset,
/// never cascading globally.
@MainActor
@Observable
public final class TranscriptModel {
    /// Set by the orchestrator per session; feeds the segmenter's language when
    /// a delta doesn't carry one.
    public var currentLanguagePair: LanguagePair?
    private let clock: Clock

    /// A speaker's current turn. Holds only the UNSEALED tail — completed
    /// sentence-pairs have already moved to `frozen`.
    private struct Turn {
        var source = ""
        var translation = ""
        var sourceLang: Language?
        var translationLang: Language?
        var lastSourceAt: Date?
        var lastTranslationAt: Date?
        let id: UUID            // stable id for the live tail bubble (→ frozen on finalize)
        let startedAt: Date
    }
    private var turns: [Speaker: Turn] = [:]
    private var frozen: [TranscriptBubble] = []

    public struct Config: Sendable {
        /// A turn's tail freezes after this much silence. 4 s = a real pause
        /// between thoughts, not a clause micro-gap.
        public var pauseSeconds: TimeInterval = 4.0
        /// Runaway guard for punctuation-less speech (no sentence to seal): the
        /// tail force-finalizes past this length so one bubble can't grow
        /// forever. Rarely hit — the model usually emits sentence punctuation.
        public var maxTailChars: Int = 500
        public var historyCap: Int = 60
        public init() {}
    }
    public var config = Config()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func ingest(_ delta: TranscriptDelta) {
        guard !delta.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Interruption: the OTHER speaker actively speaking (an `.original`
        // delta = voice activity) finalizes the current speaker's turn. Gated on
        // `.original` so a lagging translation can't trigger a false handoff.
        if delta.kind == .original {
            let other: Speaker = delta.speaker == .me ? .peer : .me
            if let ot = turns[other], !(ot.source.isEmpty && ot.translation.isEmpty) {
                finalize(other, now: clock.now())
            }
        }
        var turn = turns[delta.speaker] ?? Turn(id: UUID(), startedAt: clock.now())
        switch delta.kind {
        case .original:
            turn.source = appendChunk(turn.source, delta.text)
            turn.sourceLang = delta.language ?? turn.sourceLang
            turn.lastSourceAt = clock.now()
        case .translated:
            turn.translation = appendChunk(turn.translation, delta.text)
            turn.translationLang = delta.language ?? turn.translationLang
            turn.lastTranslationAt = clock.now()
        }
        sealCompleted(delta.speaker, &turn, now: clock.now())
        // Runaway guard: a tail that never yields a sentence (no punctuation)
        // can't seal — force-finalize so it doesn't grow without bound.
        if turn.source.count >= config.maxTailChars || turn.translation.count >= config.maxTailChars {
            turns[delta.speaker] = turn
            finalize(delta.speaker, now: clock.now())
            return
        }
        turns[delta.speaker] = turn
    }

    /// Freeze every sentence-pair that is now complete on BOTH sides, in order,
    /// removing each from the tail as it seals.
    private func sealCompleted(_ speaker: Speaker, _ turn: inout Turn, now: Date) {
        let srcLang = turn.sourceLang ?? defaultSourceLang(speaker)
        let trLang = turn.translationLang ?? defaultTranslationLang(speaker)
        while true {
            let src = SentenceSegmenter.segment(turn.source, language: srcLang)
            let tr = SentenceSegmenter.segment(turn.translation, language: trLang)
            guard let sentenceSource = src.complete.first,
                  let sentenceTranslation = tr.complete.first else { break }
            appendFrozen(speaker, id: UUID(), sentence: (sentenceSource, sentenceTranslation),
                         startedAt: turn.startedAt, now: now)
            turn.source = joined(Array(src.complete.dropFirst()) + [src.trailing])
            turn.translation = joined(Array(tr.complete.dropFirst()) + [tr.trailing])
        }
    }

    /// End a turn: seal any complete pairs, then freeze the remaining tail (the
    /// last partial sentence) as one bubble — keeping the live id so the tail
    /// locks in place — and drop the turn (index resets for the next one).
    private func finalize(_ speaker: Speaker, now: Date) {
        guard var turn = turns[speaker] else { return }
        sealCompleted(speaker, &turn, now: now)
        appendFrozen(speaker, id: turn.id, sentence: (turn.source, turn.translation),
                     startedAt: turn.startedAt, now: now)
        turns[speaker] = nil
    }

    private func appendFrozen(_ speaker: Speaker, id: UUID,
                              sentence: (source: String, translation: String),
                              startedAt: Date, now: Date) {
        let s = sentence.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = sentence.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(s.isEmpty && t.isEmpty) else { return }
        frozen.append(TranscriptBubble(
            id: id, speaker: speaker, source: s, translation: t,
            translationLost: t.isEmpty && !s.isEmpty,
            startedAt: startedAt, committedAt: now, isLive: false))
        if frozen.count > config.historyCap { frozen.removeFirst(frozen.count - config.historyCap) }
    }

    /// Time-driven: a turn whose streams have gone quiet for `pauseSeconds`
    /// finalizes. Call ~1/s from the view.
    public func tick(now: Date) {
        for (speaker, turn) in Array(turns) where isQuiet(turn, now: now, for: config.pauseSeconds) {
            finalize(speaker, now: now)   // snapshot: finalize() mutates `turns`
        }
    }

    private func isQuiet(_ turn: Turn, now: Date, for seconds: TimeInterval) -> Bool {
        let last = [turn.lastSourceAt, turn.lastTranslationAt].compactMap { $0 }.max()
        guard let last else { return false }
        return now.timeIntervalSince(last) >= seconds
    }

    // MARK: - Text assembly

    /// Append a delta chunk to a tail. Joins with a single space for
    /// space-delimited scripts, NO space for space-less scripts (CJK/Thai) or
    /// attached punctuation. Detects a cumulative restatement (a strictly-longer
    /// prefix-superset) and replaces rather than duplicating.
    private func appendChunk(_ acc: String, _ chunk: String) -> String {
        let a = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return c }
        if c.isEmpty { return a }
        if c.count > a.count && c.hasPrefix(a) { return c }   // cumulative restatement
        return joinsWithoutSpace(after: a.last, before: c.first) ? a + c : a + " " + c
    }

    /// Reassemble sentence fragments (from the segmenter) back into a tail
    /// string, script-aware, dropping empties.
    private func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.reduce("") { acc, part in
            if acc.isEmpty { return part }
            return joinsWithoutSpace(after: acc.last, before: part.first) ? acc + part : acc + " " + part
        }
    }

    /// Whether two chunks should join with no space: true for CJK/Thai
    /// (space-less scripts) on either side, or when the next chunk starts with
    /// attached punctuation. Korean (Hangul) uses inter-word spaces.
    private func joinsWithoutSpace(after last: Character?, before first: Character?) -> Bool {
        let attachedLeading: Set<Character> = [
            ".", ",", "!", "?", ";", ":", "\u{2026}",
            "\u{3002}", "\u{3001}", "\u{FF1F}", "\u{FF01}"
        ]
        if let first, attachedLeading.contains(first) { return true }
        func isSpacelessScript(_ ch: Character?) -> Bool {
            guard let value = ch?.unicodeScalars.first?.value else { return false }
            return (0x3040...0x30FF).contains(value)   // Hiragana + Katakana
                || (0x3400...0x9FFF).contains(value)   // CJK ideographs (incl. ext-A)
                || (0xF900...0xFAFF).contains(value)   // CJK compatibility ideographs
                || (0x0E00...0x0E7F).contains(value)   // Thai
        }
        return isSpacelessScript(last) || isSpacelessScript(first)
    }

    // MARK: - Output

    /// Frozen sentence bubbles + each speaker's live tail, ordered by turn
    /// START time (stable across live→frozen, so nothing changes place). Within
    /// a turn, sentences keep seal order via the stable sort (same `startedAt`).
    public var bubbles: [TranscriptBubble] {
        var out = frozen
        for (speaker, turn) in turns {
            if let bubble = liveBubble(speaker, turn) { out.append(bubble) }
        }
        return out.sorted { lhs, rhs in
            lhs.startedAt != rhs.startedAt
                ? lhs.startedAt < rhs.startedAt
                : lhs.speaker.rawValue < rhs.speaker.rawValue
        }
    }

    private func liveBubble(_ speaker: Speaker, _ turn: Turn) -> TranscriptBubble? {
        let s = turn.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let t = turn.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(s.isEmpty && t.isEmpty) else { return nil }
        return TranscriptBubble(
            id: turn.id, speaker: speaker, source: s, translation: t,
            translationLost: false, startedAt: turn.startedAt,
            committedAt: turn.lastSourceAt ?? turn.lastTranslationAt ?? turn.startedAt,
            isLive: true)
    }

    private func defaultSourceLang(_ speaker: Speaker) -> Language {
        guard let p = currentLanguagePair else { return .en }
        return speaker == .me ? p.mine : p.peer   // original is the speaker's own language
    }
    private func defaultTranslationLang(_ speaker: Speaker) -> Language {
        guard let p = currentLanguagePair else { return .en }
        return speaker == .me ? p.peer : p.mine
    }

    public func clear() { turns.removeAll(); frozen.removeAll() }
}
