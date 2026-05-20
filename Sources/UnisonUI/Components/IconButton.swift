import SwiftUI

/// Square, transparent icon button used for gear / settings / close / stop.
/// 28×28 by default with a small hover background and 0.94 press scale.
/// DESIGN.md §5.3, §5.7.
public struct IconButton<Icon: View>: View {
    public let size: CGFloat
    public let cornerRadius: CGFloat
    public let action: () -> Void
    public let icon: () -> Icon

    public init(
        size: CGFloat = 28,
        cornerRadius: CGFloat = 7,
        action: @escaping () -> Void,
        @ViewBuilder icon: @escaping () -> Icon
    ) {
        self.size = size
        self.cornerRadius = cornerRadius
        self.action = action
        self.icon = icon
    }

    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var pressed = false

    public var body: some View {
        Button(action: action) {
            icon()
                .frame(width: size, height: size)
                .foregroundStyle(hovering
                    ? UnisonColors.whiteAlpha(0.95)
                    : UnisonColors.whiteAlpha(0.55))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(hovering ? UnisonColors.whiteAlpha(0.10) : .clear)
                )
                .scaleEffect(pressed ? 0.94 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(UnisonAnimations.hover, value: hovering)
        .animation(UnisonAnimations.press, value: pressed)
    }
}

