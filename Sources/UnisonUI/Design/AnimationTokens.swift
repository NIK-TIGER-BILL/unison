import SwiftUI

/// Reusable animation curves shared across screens.
enum UnisonAnimations {
    /// Glass surfaces fading in (popover / dropdown appearance).
    static let glassAppear: Animation = .easeOut(duration: 0.18)

    /// Transcript bubble entry — soft spring with a touch of scale.
    static let bubbleIn: Animation = .spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)

    /// `active` status pulse — 1.6s ping-pong.
    static let pulseAnimation: Animation =
        .easeInOut(duration: 1.6).repeatForever(autoreverses: true)

    /// Generic state transition (selection, mode swap).
    static let state: Animation = .easeOut(duration: 0.20)
}

extension Animation {
    /// Returns `nil` when `reduce` is true so callers can short-circuit
    /// spring / repeat-forever animations for users who opted into
    /// Reduce Motion.
    func reduceMotion(_ reduce: Bool) -> Animation? {
        reduce ? nil : self
    }
}
