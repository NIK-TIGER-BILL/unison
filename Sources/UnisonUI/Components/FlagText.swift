import SwiftUI

/// Renders a flag emoji at a fixed size. Why the indirection?
///
/// macOS dark mode (and certain font renderings) can desaturate emoji
/// glyphs when applied via `.foregroundStyle(.white)`. Forcing the emoji
/// inside a `Text` whose foreground is left untouched, and never inheriting
/// a tint from the parent, keeps the colours stable.
public struct FlagText: View {
    public let flag: String
    public let size: CGFloat
    /// Spoken label for VoiceOver. When `nil`, the flag is presented
    /// without a label (decorative). Callers showing the flag alongside
    /// a separate language-name `Text` can leave this as `nil`; callers
    /// using the flag standalone should pass the language's display
    /// name so screen readers announce "Русский" instead of the raw
    /// regional-indicator glyph cluster.
    public let accessibilityName: String?

    public init(_ flag: String, size: CGFloat = 14, accessibilityName: String? = nil) {
        self.flag = flag
        self.size = size
        self.accessibilityName = accessibilityName
    }

    public var body: some View {
        Text(flag)
            .font(.system(size: size))
            // SwiftUI honors `.foregroundStyle` even for emoji on some
            // macOS builds — keep the color the emoji's own palette by
            // explicitly using `.tint(nil)` and primary style.
            .foregroundStyle(.primary)
            .accessibilityLabel(accessibilityName ?? "")
            .accessibilityHidden(accessibilityName == nil)
    }
}
