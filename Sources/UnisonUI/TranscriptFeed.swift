import Foundation
import UnisonDomain

/// "Commit and freeze" transcript feed. Turns the append-only store entries
/// into the bubbles the view renders: immutable frozen bubbles plus at most
/// one live bubble (`TranscriptGrouping.liveBubbles`).
///
/// Its one job on top of the pure derivation is lifetime: a frozen bubble is
/// removed as a WHOLE unit once it has been quiet for `window` seconds —
/// never piecewise, so a bubble never "re-initialises" by losing pieces.
/// Lifetime is measured from the bubble's own `lastActivityAt`, so a late
/// delta that revives an entry resets the clock and the bubble can't vanish
/// early. The live bubble never expires. Result is a pure function of
/// `(entries, now)` — the feed holds only config, no per-bubble memo.
@MainActor
final class TranscriptFeed {
    struct Config: Sendable {
        var finalizeAfter: TimeInterval = 2.5
        var window: TimeInterval = 30
        var maxBubbles: Int = 6
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// The bubbles to render at `now`: the live tail plus every frozen bubble
    /// whose last activity is within `window`, capped to the last `maxBubbles`.
    func visibleBubbles(entries: [TranscriptEntry], now: Date) -> [DisplayBubble] {
        visible(TranscriptGrouping.liveBubbles(
            entries: entries, now: now, finalizeAfter: config.finalizeAfter), now: now)
    }

    /// Window a PRE-BUILT bubble list (e.g. mapped from `TranscriptModel`):
    /// keep every live bubble and every frozen bubble whose last activity is
    /// within `window`, capped to the last `maxBubbles`. Per-bubble filter →
    /// removal is always whole; a live bubble always stays.
    func visible(_ all: [DisplayBubble], now: Date) -> [DisplayBubble] {
        var visible = all.filter { bubble in
            bubble.isLive || now.timeIntervalSince(bubble.lastActivityAt) <= config.window
        }
        if visible.count > config.maxBubbles {
            visible = Array(visible.suffix(config.maxBubbles))
        }
        return visible
    }
}
