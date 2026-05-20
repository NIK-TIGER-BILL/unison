import SwiftUI

/// Reusable animation curves and durations.
///
/// Centralising these keeps timing consistent across screens. Names map
/// roughly to the CSS transitions in the design HTML.
public enum UnisonAnimations {
    /// Glass surfaces fading in (popover/dropdown appearance).
    public static let glassAppear: Animation = .easeOut(duration: 0.18)

    /// Transcript bubble entry — soft spring with a touch of scale.
    public static let bubbleIn: Animation = .spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0)

    /// `active` status pulse — 1.6s ping-pong, see DESIGN.md §5.5.
    public static let pulseAnimation: Animation =
        .easeInOut(duration: 1.6).repeatForever(autoreverses: true)

    /// Generic state transition (selection, mode swap).
    public static let state: Animation = .easeOut(duration: 0.20)

    /// Hover affordances.
    public static let hover: Animation = .easeOut(duration: 0.15)

    /// Button press — short and snappy.
    public static let press: Animation = .easeInOut(duration: 0.08)

    /// Dropdown open / close.
    public static let dropdown: Animation = .easeOut(duration: 0.16)
}
