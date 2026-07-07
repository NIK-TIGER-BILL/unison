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
        public var translationLagTimeout: TimeInterval = 5.0
        public var historyCap: Int = 40
        public init() {}
    }
    public var config = Config()

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func ingest(_ delta: TranscriptDelta) {
        guard !delta.text.isEmpty else { return }
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
    }

    /// Deltas are appended; leading/trailing spacing is the model's. Single-
    /// spaced join keeps clause fragments readable.
    private func appendChunk(_ acc: String, _ chunk: String) -> String {
        let a = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return c }
        if c.isEmpty { return a }
        return a + " " + c
    }

    /// Frozen bubbles (oldest→newest) followed by each speaker's live bubble.
    public var bubbles: [TranscriptBubble] {
        var out = frozen
        for (speaker, seg) in live where !(seg.source.isEmpty && seg.translation.isEmpty) {
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

    /// Time-driven commits (pause / translation-lag). Call ~1/s from the view.
    public func tick(now: Date) {
        // snapshot: commit() mutates `live`
        for (speaker, seg) in Array(live) where isQuiet(seg, now: now, for: config.pauseSeconds) {
            commit(speaker, seg, now: now)
        }
    }

    private func isQuiet(_ seg: Segment, now: Date, for seconds: TimeInterval) -> Bool {
        let last = [seg.lastSourceAt, seg.lastTranslationAt].compactMap { $0 }.max()
        guard let last else { return false }
        return now.timeIntervalSince(last) >= seconds
    }

    /// Freeze the whole segment as ONE bubble (source↔translation paired as a
    /// unit — the same speech span) and reset the speaker's live segment.
    private func commit(_ speaker: Speaker, _ seg: Segment, now: Date) {
        let source = seg.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        live[speaker] = nil
        guard !(source.isEmpty && translation.isEmpty) else { return }
        frozen.append(TranscriptBubble(
            id: seg.id, speaker: speaker, source: source, translation: translation,
            translationLost: false, committedAt: now, isLive: false))
        if frozen.count > config.historyCap { frozen.removeFirst(frozen.count - config.historyCap) }
    }

    public func clear() { live.removeAll(); frozen.removeAll() }
}
