import SwiftUI

/// Design-system font tokens for the Unison UI.
///
/// DESIGN.md §2 specifies **DM Sans** for UI and **IBM Plex Mono** for
/// data/captions. We do not ship custom fonts in v1 to avoid a bundling
/// pipeline; system equivalents are used and centralised here so a future
/// swap is a one-file change.
///
/// - DM Sans → `.system(design: .default)`
/// - IBM Plex Mono → `.system(design: .monospaced)`
///
/// Tracking that the design uses (e.g. caps `+0.13em`) is applied at the
/// call site via SwiftUI's `.tracking(_:)` modifier — see `sectionHead`.
public enum UnisonFonts {
    /// Window titles (h1) — DM Sans 300 in design. We approximate with
    /// `.system(weight: .light)`. Default 18pt covers popover brand text;
    /// onboarding header uses ~26pt.
    public static func uiTitle(_ size: CGFloat = 18) -> Font {
        .system(size: size, weight: .light, design: .default)
    }

    /// Body / generic UI text — DM Sans 400/500.
    public static func uiBody(_ size: CGFloat = 13) -> Font {
        .system(size: size, weight: .regular, design: .default)
    }

    /// Mono caption — IBM Plex Mono in design, monospaced system here.
    public static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Caps section header (e.g. `АУДИО`, `OPENAI`). Uses mono at 10pt;
    /// pair with `.tracking(1.4)` and `.textCase(.uppercase)` at the call
    /// site for the 0.14em letter-spacing the design specifies.
    public static func sectionHead() -> Font {
        .system(size: 10, weight: .regular, design: .monospaced)
    }
}
