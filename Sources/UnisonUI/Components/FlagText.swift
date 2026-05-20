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

    public init(_ flag: String, size: CGFloat = 14) {
        self.flag = flag
        self.size = size
    }

    public var body: some View {
        Text(flag)
            .font(.system(size: size))
            // SwiftUI honors `.foregroundStyle` even for emoji on some
            // macOS builds — keep the color the emoji's own palette by
            // explicitly using `.tint(nil)` and primary style.
            .foregroundStyle(.primary)
    }
}

