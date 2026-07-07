import Foundation
import UnisonDomain

/// Recency window for the transcript bubbles. Takes the bubbles mapped from
/// `TranscriptModel` and drops each frozen one as a WHOLE unit once it has
/// been quiet for `window` seconds — never piecewise, so a bubble never
/// "re-initialises" by losing pieces. Lifetime is measured from the bubble's
/// own `lastActivityAt`. The live bubble never expires. Pure over
/// `(bubbles, now)` — holds only config, no per-bubble memo.
@MainActor
final class TranscriptFeed {
    struct Config: Sendable {
        var window: TimeInterval = 30
        var maxBubbles: Int = 6
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// Window a pre-built bubble list (mapped from `TranscriptModel`): keep
    /// every live bubble and every frozen bubble whose last activity is within
    /// `window`, capped to the last `maxBubbles`. Per-bubble filter → removal
    /// is always whole; a live bubble always stays.
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
