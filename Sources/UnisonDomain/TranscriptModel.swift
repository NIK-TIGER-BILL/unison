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

    public func clear() { live.removeAll(); frozen.removeAll() }
}
