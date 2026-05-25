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

    @SwiftUI.State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // Suppress the macOS Full Keyboard Access focus ring. The
        // gear / close / stop icons are decorative chrome — they
        // already get a hover/press treatment from `.glass`, and the
        // bright accent-coloured ring (which macOS draws around the
        // first focusable button when a panel opens) reads as a
        // permanent "selected" state on the popover. Buttons remain
        // reachable via Tab (`.focusable(true)`) but the ring isn't
        // drawn at rest.
        .focusEffectDisabled()
        // Explicit hover affordance. The system's `.buttonStyle(.glass)`
        // does animate its glass material on hover, but for SF Symbol-only
        // icon buttons on a dark popover background the system change is
        // too subtle to read as an affordance — so we layer a small
        // brightness lift + scale bump on top to make the cursor's
        // presence unmistakable. Same pattern as `PrimaryGlassButton`.
        .brightness(isHovered ? 0.10 : 0)
        .scaleEffect(isHovered ? 1.06 : 1.0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(label)
        .help(label)
    }
}
