import SwiftUI

/// Square / circular icon button used for gear / settings / close /
/// stop. Uses Apple's native `.buttonStyle(.glass)` with a circular
/// border shape on macOS 26 — the system supplies the hover / press /
/// pressed-glow treatment automatically. DESIGN.md §5.3, §5.7.
///
/// `size` and `cornerRadius` are accepted for API compatibility but
/// are mostly informational now — control size and border shape are
/// picked from `controlSize(_:)` / `buttonBorderShape(_:)`. The
/// `size` parameter still sets the icon's frame so existing call
/// sites that depend on a specific tap target (e.g. 28×28) keep
/// their pixel-accurate alignment.
///
/// `label` is REQUIRED — it powers both VoiceOver (`accessibilityLabel`)
/// and the hover tooltip (`.help`) so icon-only callers don't have to
/// repeat themselves at every call site.
public struct IconButton<Icon: View>: View {
    public let label: String
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public let action: () -> Void
    public let icon: () -> Icon

    public init(
        label: String,
        size: CGFloat = 28,
        cornerRadius: CGFloat = 7,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.label = label
        self.size = size
        self.cornerRadius = cornerRadius
        self.action = action
        self.icon = icon
    }

    public var body: some View {
        Button(action: action) {
            icon()
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        .help(label)
    }
}
