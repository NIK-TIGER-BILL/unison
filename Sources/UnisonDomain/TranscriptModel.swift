import Foundation
import Observation

public struct TranscriptBubble: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let source: String
    public let translation: String
    public let translationLost: Bool
    /// When the utterance's segment STARTED. Stable across the live→frozen
    /// transition, so bubbles order by this and a bubble never changes place
    /// (a later-starting speaker can't jump above an earlier one).
    public let startedAt: Date
    /// When the bubble last had activity — the freeze instant for a frozen
    /// bubble, the last delta for a live one. Drives the recency-window
    /// expiry, NOT ordering.
    public let committedAt: Date
    public let isLive: Bool
}

/// Turns a speaker's streamed source+translation deltas into transcript
/// bubbles. Deliberately simple: a bubble is ONE continuous speech segment,
/// frozen WHOLE — never re-split by sentence (that read as jumpy: the bubble
/// grows, then suddenly chops into pieces). A speaker's segment ends on the
/// first of: a long pause (`pauseSeconds` of silence), the OTHER speaker
/// taking a turn (interruption), or a length safety cap (`maxSegmentChars`).
@MainActor
@Observable
public final class TranscriptModel {
    /// Set by the orchestrator per session. Not read internally (segmentation
    /// is language-agnostic now); kept as session context.
    public var currentLanguagePair: LanguagePair?
    private let clock: Clock

    /// Per-speaker accumulator for the current (still-forming) segment.
    private struct Segment {
        var source = ""
        var translation = ""
        var lastSourceAt: Date?
        var lastTranslationAt: Date?
        let id: UUID
        let startedAt: Date
    }
    private var live: [Speaker: Segment] = [:]
    private var frozen: [TranscriptBubble] = []

    public struct Config: Sendable {
        /// A speaker's segment freezes after this much silence. Big on purpose
        /// — real thinking pauses, not clause-level micro-gaps. Small pauses
        /// would chop one thought into many bubbles.
        public var pauseSeconds: TimeInterval = 7.0
        /// Safety cap so a monologue with no pause can't grow forever. Rarely
        /// hit; NOT a primary boundary (pauses / interruptions are).
        public var maxSegmentChars: Int = 240
        public var historyCap: Int = 40
        public init() {}
    }
    public var config = Config()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func ingest(_ delta: TranscriptDelta) {
        guard !delta.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Interruption: the OTHER speaker actively speaking (an `.original`
        // delta = voice activity) seals the current speaker's bubble. Gated on
        // `.original` so a lagging translation of the SAME turn — which arrives
        // as the other speaker's `.translated` — can't trigger a false handoff.
        if delta.kind == .original {
            let other: Speaker = delta.speaker == .me ? .peer : .me
            if let otherSeg = live[other], !(otherSeg.source.isEmpty && otherSeg.translation.isEmpty) {
                commit(other, otherSeg, now: clock.now())
            }
        }
        var seg = live[delta.speaker] ?? Segment(id: UUID(), startedAt: clock.now())
        switch delta.kind {
        case .original:
            seg.source = appendChunk(seg.source, delta.text)
            seg.lastSourceAt = clock.now()
        case .translated:
            seg.translation = appendChunk(seg.translation, delta.text)
            seg.lastTranslationAt = clock.now()
        }
        live[delta.speaker] = seg
        // Safety cap only (see Config.maxSegmentChars) — never a primary boundary.
        if seg.source.count >= config.maxSegmentChars || seg.translation.count >= config.maxSegmentChars {
            commit(delta.speaker, seg, now: clock.now())
        }
    }

    /// Append a delta chunk to the accumulation. Chunks join with a single
    /// space for space-delimited scripts, but with NO space for scripts that
    /// don't use inter-word spaces (CJK, Thai) or before attached punctuation —
    /// otherwise "今天" + "很好。" would render as "今天 很好。".
    private func appendChunk(_ acc: String, _ chunk: String) -> String {
        let a = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return c }
        if c.isEmpty { return a }
        // Cumulative restatement (some models resend the whole transcript, each
        // longer than the last): the new chunk STRICTLY extends the accumulation
        // → replace. Must be strictly longer — an identical repeat is a normal
        // append (a string is its own prefix), not a restatement.
        if c.count > a.count && c.hasPrefix(a) { return c }
        return joinsWithoutSpace(after: a.last, before: c.first) ? a + c : a + " " + c
    }

    /// Whether two chunks should join with no space: true for CJK/Thai
    /// (space-less scripts) on either side, or when the next chunk starts with
    /// attached punctuation. Korean (Hangul) uses inter-word spaces, so it is
    /// deliberately NOT treated as space-less.
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

    /// Frozen bubbles + each speaker's live bubble, ordered by the utterance's
    /// START time — stable across the live→frozen transition, so a bubble never
    /// changes place (the reorder "jump" this model avoids). A quick
    /// cross-speaker handoff can't invert order the way sorting on the
    /// heterogeneous `committedAt` (freeze-instant vs. last-activity) would. The
    /// speaker tiebreak makes an exact same-instant cross-speaker start
    /// deterministic.
    public var bubbles: [TranscriptBubble] {
        var out = frozen
        for (speaker, seg) in live where !(seg.source.isEmpty && seg.translation.isEmpty) {
            out.append(liveBubble(speaker, seg))
        }
        return out.sorted { lhs, rhs in
            lhs.startedAt != rhs.startedAt
                ? lhs.startedAt < rhs.startedAt
                : lhs.speaker.rawValue < rhs.speaker.rawValue
        }
    }

    private func liveBubble(_ speaker: Speaker, _ seg: Segment) -> TranscriptBubble {
        TranscriptBubble(
            id: seg.id, speaker: speaker, source: seg.source, translation: seg.translation,
            translationLost: false,
            startedAt: seg.startedAt,
            committedAt: seg.lastSourceAt ?? seg.lastTranslationAt ?? seg.startedAt,
            isLive: true)
    }

    /// Time-driven commit: a speaker whose streams have gone quiet for
    /// `pauseSeconds` freezes as a segment. Call ~1/s from the view.
    public func tick(now: Date) {
        for (speaker, seg) in Array(live) where isQuiet(seg, now: now, for: config.pauseSeconds) {
            commit(speaker, seg, now: now)   // snapshot: commit() mutates `live`
        }
    }

    private func isQuiet(_ seg: Segment, now: Date, for seconds: TimeInterval) -> Bool {
        let last = [seg.lastSourceAt, seg.lastTranslationAt].compactMap { $0 }.max()
        guard let last else { return false }
        return now.timeIntervalSince(last) >= seconds
    }

    /// Freeze the WHOLE segment as ONE bubble (source↔translation as a unit —
    /// the same speech span) and reset the speaker's live segment. The bubble
    /// reuses the live segment's `id`, so the freeze reads as an in-place lock
    /// (not a delete+insert) to the diffing view. `translationLost` marks a
    /// segment that sealed with a source but no translation.
    private func commit(_ speaker: Speaker, _ seg: Segment, now: Date) {
        let source = seg.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        live[speaker] = nil
        guard !(source.isEmpty && translation.isEmpty) else { return }
        frozen.append(TranscriptBubble(
            id: seg.id, speaker: speaker, source: source, translation: translation,
            translationLost: translation.isEmpty && !source.isEmpty,
            startedAt: seg.startedAt, committedAt: now, isLive: false))
        if frozen.count > config.historyCap { frozen.removeFirst(frozen.count - config.historyCap) }
    }

    public func clear() { live.removeAll(); frozen.removeAll() }
}
