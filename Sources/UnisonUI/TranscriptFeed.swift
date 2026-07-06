import Foundation
import UnisonDomain

/// Stateful "commit and freeze" transcript feed. Turns the append-only
/// store entries into the bubbles the view renders: immutable frozen
/// bubbles plus at most one live bubble (`TranscriptGrouping.liveBubbles`).
///
/// Its one job on top of the pure derivation is lifetime: each frozen
/// bubble is stamped with the instant it first froze and is later removed
/// as a WHOLE unit once `window` seconds have passed — never piecewise, so
/// a bubble never "re-initialises" by losing pieces. A live bubble never
/// expires (it has no freeze time yet).
///
/// Plain class (deliberately NOT `@Observable`): the freeze-time memo is
/// invisible to SwiftUI, so recording it from inside a view read cannot
/// trigger a re-render loop. The rendered result is still a pure function
/// of `(entries, now)` — the memo only pins each bubble's start-of-life.
@MainActor
final class TranscriptFeed {
    struct Config: Sendable {
        var finalizeAfter: TimeInterval = 2.5
        var window: TimeInterval = 30
        var maxBubbles: Int = 6
    }

    private let config: Config
    /// When each frozen bubble id was first seen frozen — its lifetime clock.
    private var finalizedAt: [UUID: Date] = [:]

    init(config: Config = Config()) {
        self.config = config
    }

    /// The bubbles to render at `now`: still-living frozen bubbles + the
    /// live tail, capped to the last `maxBubbles`.
    func visibleBubbles(entries: [TranscriptEntry], now: Date) -> [DisplayBubble] {
        let all = TranscriptGrouping.liveBubbles(
            entries: entries, now: now, finalizeAfter: config.finalizeAfter)
        // Stamp each bubble the first instant it appears frozen — that is
        // the start of its lifetime. Live bubbles get no stamp yet.
        for bubble in all where !bubble.isLive && finalizedAt[bubble.id] == nil {
            finalizedAt[bubble.id] = now
        }
        // Keep the live bubble and every frozen bubble still inside its
        // window. The filter is per-bubble, so removal is always whole.
        var visible = all.filter { bubble in
            if bubble.isLive { return true }
            guard let frozenAt = finalizedAt[bubble.id] else { return true }
            return now.timeIntervalSince(frozenAt) <= config.window
        }
        if visible.count > config.maxBubbles {
            visible = Array(visible.suffix(config.maxBubbles))
        }
        return visible
    }

    /// Drop all lifetime memory (call on session clear so a new session's
    /// bubbles don't inherit stale freeze times).
    func clear() {
        finalizedAt.removeAll()
    }
}
