import SwiftUI

/// Font tokens. Currently only the IBM Plex Mono caption is used —
/// title / body / section headers default to inline `.font(...)`
/// at the call site.
enum UnisonFonts {
    /// Mono caption — IBM Plex Mono in the design, monospaced system here.
    static func mono(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
}
