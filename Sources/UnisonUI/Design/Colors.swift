import SwiftUI

/// Design-system color tokens. Semantic accents + a neutral
/// `whiteAlpha(_:)` helper used in place of a brand tint.
public enum UnisonColors {
    /// `#58e09a` — ready / OK / toggle-on.
    public static let ready = Color(red: 0x58 / 255, green: 0xe0 / 255, blue: 0x9a / 255)

    /// `#5ac8fa` — translating / pulse / active menubar.
    public static let active = Color(red: 0x5a / 255, green: 0xc8 / 255, blue: 0xfa / 255)

    /// `#ffc060` — validation warnings.
    public static let warn = Color(red: 0xff / 255, green: 0xc0 / 255, blue: 0x60 / 255)

    /// `#ff7a8c` — error state (menubar badge, error rows).
    public static let error = Color(red: 0xff / 255, green: 0x7a / 255, blue: 0x8c / 255)

    /// White at the given opacity. Used in place of a brand tint for
    /// hover / focus / selected states.
    public static func whiteAlpha(_ a: Double) -> Color {
        Color.white.opacity(a)
    }
}
