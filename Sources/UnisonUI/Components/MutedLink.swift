import SwiftUI

/// External-link button styled as muted white text with a small ↗ glyph.
///
/// Used wherever the design specifies a "ghost" link — Onboarding's
/// `Получить ключ`, Settings' `MIT`, `github.com/unison`, etc. Always
/// pairs with a host callback (the `UnisonUI` module cannot import
/// `AppKit`, so URL handling is the caller's responsibility).
///
/// Visual spec (DESIGN.md §5.16, "muted link"):
/// - text: 11.5pt, white at 50% opacity
/// - trailing icon: `arrow.up.right`, 9pt, 70% opacity
/// - 4pt spacing between text and icon
public struct MutedLink: View {
    public let title: String
    public let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11.5))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .opacity(0.7)
            }
            .foregroundStyle(UnisonColors.whiteAlpha(0.5))
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
