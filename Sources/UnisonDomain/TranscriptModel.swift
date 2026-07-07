import Foundation
import Observation

public struct TranscriptBubble: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let source: String
    public let translation: String
    public let translationLost: Bool
    public let committedAt: Date
    public let isLive: Bool
}

@MainActor
@Observable
public final class TranscriptModel {
    public var currentLanguagePair: LanguagePair?
    private let clock: Clock

    /// Per-speaker accumulator for the current (still-forming) segment.
    private struct Segment {
        var source = ""
        var translation = ""
        var sourceLang: Language?
        var translationLang: Language?
        var lastSourceAt: Date?
        var lastTranslationAt: Date?
        let id: UUID
        let startedAt: Date
    }
    private var live: [Speaker: Segment] = [:]
    private var frozen: [TranscriptBubble] = []

    public struct Config: Sendable {
        public var pauseSeconds: TimeInterval = 2.0
        public var maxSegmentChars: Int = 240
        public var historyCap: Int = 40
        public init() {}
    }
    public var config = Config()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func ingest(_ delta: TranscriptDelta) {
        guard !delta.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var seg = live[delta.speaker] ?? Segment(id: UUID(), startedAt: clock.now())
        switch delta.kind {
        case .original:
            seg.source = appendChunk(seg.source, delta.text)
            seg.sourceLang = delta.language ?? seg.sourceLang
            seg.lastSourceAt = clock.now()
        case .translated:
            seg.translation = appendChunk(seg.translation, delta.text)
            seg.translationLang = delta.language ?? seg.translationLang
            seg.lastTranslationAt = clock.now()
        }
        live[delta.speaker] = seg
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

    /// Frozen bubbles (oldest→newest) followed by each speaker's live bubble.
    /// Live segments are appended in a deterministic start order so two
    /// simultaneously-active speakers never swap places between redraws.
    public var bubbles: [TranscriptBubble] {
        var out = frozen
        let liveInStartOrder = live.sorted { lhs, rhs in
            lhs.value.startedAt != rhs.value.startedAt
                ? lhs.value.startedAt < rhs.value.startedAt
                : lhs.key.rawValue < rhs.key.rawValue
        }
        for (speaker, seg) in liveInStartOrder where !(seg.source.isEmpty && seg.translation.isEmpty) {
            out.append(liveBubble(speaker, seg))
        }
        return out.sorted { $0.committedAt < $1.committedAt }
    }

    private func liveBubble(_ speaker: Speaker, _ seg: Segment) -> TranscriptBubble {
        TranscriptBubble(
            id: seg.id, speaker: speaker, source: seg.source, translation: seg.translation,
            translationLost: false,
            committedAt: seg.lastSourceAt ?? seg.lastTranslationAt ?? seg.startedAt,
            isLive: true)
    }

    /// Time-driven commit: a speaker whose streams have gone quiet for
    /// `pauseSeconds` freezes as a segment. Call ~1/s from the view. A segment
    /// whose translation never arrived freezes source-only with
    /// `translationLost` set (handled in `commit`).
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

    /// Freeze the segment's source↔translation, splitting into per-sentence
    /// bubbles when both sides agree on sentence count (safe 1:1 pairing);
    /// otherwise freeze the whole segment as ONE bubble, and reset the
    /// speaker's live segment. The first frozen bubble reuses the live
    /// segment's `id` so the freeze reads as an in-place lock (not a
    /// delete+insert) to the diffing view; extra split sentences are genuine
    /// inserts.
    private func commit(_ speaker: Speaker, _ seg: Segment, now: Date) {
        let source = seg.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        live[speaker] = nil
        guard !(source.isEmpty && translation.isEmpty) else { return }

        for (offset, pair) in pairs(source: source, translation: translation,
                                    sourceLang: seg.sourceLang ?? defaultSourceLang(speaker),
                                    translationLang: seg.translationLang ?? defaultTranslationLang(speaker)).enumerated() {
            frozen.append(TranscriptBubble(
                id: offset == 0 ? seg.id : UUID(),
                speaker: speaker, source: pair.0, translation: pair.1,
                translationLost: pair.1.isEmpty && !pair.0.isEmpty,
                committedAt: now, isLive: false))
        }
        if frozen.count > config.historyCap { frozen.removeFirst(frozen.count - config.historyCap) }
    }

    /// Pair source↔translation for a committed segment. If both sides split
    /// into the SAME number of sentences, pair them 1:1 (nice, safe). If the
    /// counts differ, do NOT risk a wrong split — emit ONE whole-segment pair.
    private func pairs(source: String, translation: String,
                       sourceLang: Language, translationLang: Language) -> [(String, String)] {
        let src = SentenceSegmenter.segment(source, language: sourceLang)
        let tr = SentenceSegmenter.segment(translation, language: translationLang)
        let srcSentences = src.complete + (src.trailing.isEmpty ? [] : [src.trailing])
        let trSentences = tr.complete + (tr.trailing.isEmpty ? [] : [tr.trailing])
        if srcSentences.count == trSentences.count && srcSentences.count > 1 {
            return Array(zip(srcSentences, trSentences))
        }
        return [(source, translation)]
    }

    private func defaultSourceLang(_ speaker: Speaker) -> Language {
        // Original is the speaker's own language.
        guard let p = currentLanguagePair else { return .en }
        return speaker == .me ? p.mine : p.peer
    }
    private func defaultTranslationLang(_ speaker: Speaker) -> Language {
        guard let p = currentLanguagePair else { return .en }
        return speaker == .me ? p.peer : p.mine
    }

    public func clear() { live.removeAll(); frozen.removeAll() }
}
