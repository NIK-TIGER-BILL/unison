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
    /// `window`, capped to `maxBubbles`. Removal is always whole. A live bubble
    /// ALWAYS stays — the cap trims only the oldest FROZEN bubbles. (A naive
    /// `suffix(maxBubbles)` would drop a long-running live segment, which sorts
    /// to the front by `startedAt`, once the other speaker commits enough newer
    /// frozen bubbles — making the actively-forming bubble vanish.)
    func visible(_ all: [DisplayBubble], now: Date) -> [DisplayBubble] {
        let filtered = all.filter { bubble in
            bubble.isLive || now.timeIntervalSince(bubble.lastActivityAt) <= config.window
        }
        guard filtered.count > config.maxBubbles else { return filtered }
        let liveCount = filtered.lazy.filter(\.isLive).count
        var frozenSlots = max(0, config.maxBubbles - liveCount)
        var keep = Set<UUID>()
        for bubble in filtered.reversed() {   // newest → oldest
            if bubble.isLive {
                keep.insert(bubble.id)
            } else if frozenSlots > 0 {
                keep.insert(bubble.id)
                frozenSlots -= 1
            }
        }
        return filtered.filter { keep.contains($0.id) }
    }
}
