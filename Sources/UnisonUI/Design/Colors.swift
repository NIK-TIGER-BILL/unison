import SwiftUI

/// Design-system color tokens for the Unison UI.
///
/// Anchored to DESIGN.md §3. The palette is intentionally minimal: a
/// neutral base (white-on-dark via opacity) plus four semantic accents.
/// There is **no** brand accent color — selection / focus / hover are
/// expressed through `whiteAlpha(_:)` and font weight, never tint.
public enum UnisonColors {
    // MARK: - Page level

    /// `#08080a` — base background for design pages and aurora floor.
    public static let pageBg = Color(red: 0x08 / 255, green: 0x08 / 255, blue: 0x0a / 255)

    /// `#f5f5f7` — primary foreground text.
    public static let pageFg = Color(red: 0xf5 / 255, green: 0xf5 / 255, blue: 0xf7 / 255)

    /// `#8e8e93` — muted / secondary text.
    public static let pageMute = Color(red: 0x8e / 255, green: 0x8e / 255, blue: 0x93 / 255)

    // MARK: - Semantic accents

    /// `#58e09a` — ready / OK / toggle-on.
    public static let ready = Color(red: 0x58 / 255, green: 0xe0 / 255, blue: 0x9a / 255)

    /// `#5ac8fa` — translating / pulse / active menubar.
    public static let active = Color(red: 0x5a / 255, green: 0xc8 / 255, blue: 0xfa / 255)

    /// `#ffc060` — validation warnings.
    public static let warn = Color(red: 0xff / 255, green: 0xc0 / 255, blue: 0x60 / 255)

    /// `#ff6e82` — destructive / stop button gradient.
    public static let stop = Color(red: 0xff / 255, green: 0x6e / 255, blue: 0x82 / 255)

    /// `#ff7a8c` — error state (menubar badge, error rows).
    public static let error = Color(red: 0xff / 255, green: 0x7a / 255, blue: 0x8c / 255)

    // MARK: - Coral destructive palette
    //
    // Two RGB stops define the destructive (Stop) gradient seen on the
    // primary "Остановить перевод" button and the confirmation modal.
    // Centralised so any future destructive surface uses the same tint.

    /// `#ff6e82` — top stop of the destructive gradient.
    public static let coralTop = Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255)

    /// `#dc3c5a` — bottom stop of the destructive gradient / its shadow tint.
    public static let coralBottom = Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255)

    // MARK: - Neutral helpers

    /// White at the given opacity. Used everywhere instead of an accent
    /// color for hover / focus / selected states.
    public static func whiteAlpha(_ a: Double) -> Color {
        Color.white.opacity(a)
    }
}
