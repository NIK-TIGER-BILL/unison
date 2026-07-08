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
    /// Newest activity for this bubble (a frozen bubble's commit instant). The
    /// feed expires a frozen bubble `window` after this instant; a live bubble
    /// never expires.
    let lastActivityAt: Date
}

/// Groups the ordered `DisplayBubble`s (mapped from `TranscriptModel`) into the
/// speaker-run `BubbleGroup`s the view renders.
enum TranscriptGrouping {
    /// Bucket the ordered `DisplayBubble`s into the speaker-run `BubbleGroup`s
    /// the view renders, deriving `isFirstInGroup` / `isLastInGroup` and
    /// carrying each bubble's id, text, `isLive`, and `translationLost` through
    /// unchanged. Pure.
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
}
