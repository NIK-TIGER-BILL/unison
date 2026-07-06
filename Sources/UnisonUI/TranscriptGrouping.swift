import Foundation
import UnisonDomain

/// One bubble the transcript renders. A frozen bubble (`isLive == false`)
/// is immutable: once emitted, its `id` and text never change again — it
/// only appears whole and later disappears whole. At most one bubble is
/// live (the utterance currently being formed at the bottom). The live
/// bubble reuses the id it will carry once frozen, so locking in place is
/// a state change on the SAME SwiftUI identity, not a re-insert.
struct DisplayBubble: Identifiable, Equatable, Sendable {
    let id: UUID
    let speaker: Speaker
    let primaryText: String
    let secondaryText: String
    let isLive: Bool
    let translationLost: Bool
}

/// Pure "commit and freeze" derivation of the transcript bubbles.
///
/// Consecutive same-speaker entries are grouped into utterances; each
/// finished utterance is a frozen, immutable bubble, and the trailing,
/// still-forming one is the single live bubble. Within a bubble the member
/// entries' originals and translations are concatenated in entry order and
/// never re-split on punctuation — so the store's per-entry original↔
/// translation pairing stays intact and abbreviations like "и т.д." can't
/// fragment a bubble.
enum TranscriptGrouping {
    /// Derive the ordered display bubbles from the raw store entries.
    /// A bubble's `id` is its first entry's id, stable from live → frozen
    /// and across re-derivations. A run's last utterance stays live until
    /// both sides read as a finished sentence (giving the lagging
    /// translation time to land) or the run goes quiet for `finalizeAfter`
    /// seconds. Pure.
    static func liveBubbles(
        entries: [TranscriptEntry],
        now: Date,
        finalizeAfter: TimeInterval = 2.5
    ) -> [DisplayBubble] {
        let runs = speakerRuns(entries)
        var out: [DisplayBubble] = []
        for (runIndex, run) in runs.enumerated() {
            let isLastRun = runIndex == runs.count - 1
            let speaker = run[0].speaker
            let groups = utteranceGroups(run)
            for (groupIndex, group) in groups.enumerated() {
                let original = reconstructRunText(group.map { $0.originalText ?? "" })
                let translation = reconstructRunText(group.map { $0.translatedText })
                if original.isEmpty && translation.isEmpty { continue }

                let runAtRisk = group.contains { $0.translationAtRisk }
                let lastActivity = group.map { $0.lastActivityAt }.max() ?? group[0].timestamp
                let active = now.timeIntervalSince(lastActivity) <= finalizeAfter
                let isLastGroup = isLastRun && groupIndex == groups.count - 1
                // The current utterance stays live (mutable, grows in place)
                // until BOTH sides read as a finished sentence — giving the
                // lagging translation time to land — or the run goes quiet.
                let settled = endsSentence(original) && endsSentence(translation)
                let isLive = isLastGroup && active && !settled

                out.append(makeDisplayBubble(
                    id: group[0].id,
                    speaker: speaker,
                    text: (original, translation),
                    isLive: isLive,
                    runAtRisk: runAtRisk))
            }
        }
        return out
    }

    /// Bucket the ordered `DisplayBubble`s into the speaker-run
    /// `BubbleGroup`s the view renders, deriving `isFirstInGroup` /
    /// `isLastInGroup` and carrying each bubble's id, text, `isLive`, and
    /// `translationLost` through unchanged. Pure.
    static func groupDisplayBubbles(_ bubbles: [DisplayBubble]) -> [BubbleGroup] {
        var groups: [BubbleGroup] = []
        var run: [DisplayBubble] = []

        func flush() {
            guard let head = run.first else { return }
            let lastIdx = run.count - 1
            let vms = run.enumerated().map { i, b in
                BubbleViewModel(
                    id: b.id,
                    speaker: b.speaker,
                    primaryText: b.primaryText,
                    secondaryText: b.secondaryText,
                    isFirstInGroup: i == 0,
                    isLastInGroup: i == lastIdx,
                    isLive: b.isLive,
                    translationLost: b.translationLost
                )
            }
            groups.append(BubbleGroup(id: head.id, speaker: head.speaker, bubbles: vms))
            run = []
        }

        for bubble in bubbles {
            if let last = run.last, last.speaker != bubble.speaker { flush() }
            run.append(bubble)
        }
        flush()
        return groups
    }

    // MARK: - Private

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    /// Marks that may sit AFTER a terminator without ending the sentence,
    /// e.g. `он сказал "Да."` or `(готово.)`.
    private static let sentenceClosers: Set<Character> = ["\"", "'", ")", "]", "}", "»", "”", "’"]

    /// Whether `text` ends with sentence-final punctuation (ignoring trailing
    /// whitespace and closing quotes/brackets). Empty text → false.
    private static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, last.isWhitespace || sentenceClosers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return false }
        return sentenceTerminators.contains(last)
    }

    /// Split a speaker run into utterance groups: entries accumulate until
    /// one whose ORIGINAL (the speaker's own words) ends a sentence, which
    /// closes the group. Trailing entries with no terminator form the final,
    /// still-forming group. So clause-fragment turns merge into one
    /// sentence-sized bubble, while each entry's text stays whole.
    private static func utteranceGroups(_ run: [TranscriptEntry]) -> [[TranscriptEntry]] {
        var groups: [[TranscriptEntry]] = []
        var current: [TranscriptEntry] = []
        for entry in run {
            current.append(entry)
            let original = entry.originalText ?? ""
            let boundary = original.isEmpty ? entry.translatedText : original
            if endsSentence(boundary) {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    /// Bucket entries into maximal runs of the same speaker.
    private static func speakerRuns(_ entries: [TranscriptEntry]) -> [[TranscriptEntry]] {
        var runs: [[TranscriptEntry]] = []
        for entry in entries {
            if var last = runs.last, last.last?.speaker == entry.speaker {
                last.append(entry)
                runs[runs.count - 1] = last
            } else {
                runs.append([entry])
            }
        }
        return runs
    }

    /// Concatenate a group's per-entry text (clause fragments) into one
    /// utterance string, single-spaced.
    private static func reconstructRunText(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Build one `DisplayBubble`. Primary / secondary follow the speaker
    /// convention (`.me` shows the original bold, `.peer` shows the
    /// translation bold). `translationLost` marks a pause/reconnect drop
    /// where no translation arrived.
    private static func makeDisplayBubble(
        id: UUID,
        speaker: Speaker,
        text: (original: String, translation: String),
        isLive: Bool,
        runAtRisk: Bool
    ) -> DisplayBubble {
        let primary: String
        let secondary: String
        switch speaker {
        case .me:
            primary = text.original
            secondary = text.translation
        case .peer:
            primary = text.translation
            secondary = text.original
        }
        return DisplayBubble(
            id: id,
            speaker: speaker,
            primaryText: primary,
            secondaryText: secondary,
            isLive: isLive,
            translationLost: runAtRisk && text.translation.isEmpty
        )
    }
}
