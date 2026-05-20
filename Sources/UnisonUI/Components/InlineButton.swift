import SwiftUI

/// Small bordered button used inline in Settings rows.
/// Two variants per DESIGN.md §5.16:
/// - `.base`: translucent white-on-glass.
/// - `.primary`: brighter white-filled.
public struct InlineButton: View {
    public enum Variant: Equatable, Sendable {
        case base
        case primary
    }

    public let title: String
    public let icon: Image?
    public let variant: Variant
    public let isLoading: Bool
    public let action: () -> Void

    public init(
        _ title: String,
        icon: Image? = nil,
        variant: Variant = .base,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.isLoading = isLoading
        self.action = action
    }

    @Environment(\.isEnabled) private var isEnabled
    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var spinAngle = 0.0

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(Color.white, lineWidth: 1.3)
                        .frame(width: 10, height: 10)
                        .rotationEffect(.degrees(spinAngle))
                        .onAppear {
                            withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                                spinAngle = 360
                            }
                        }
                } else if let icon = icon {
                    icon
                        .font(.system(size: 10, weight: .regular))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .foregroundStyle(textColor)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { hovering = $0 }
        .animation(UnisonAnimations.hover, value: hovering)
    }

    private var textColor: Color {
        switch variant {
        case .base:    UnisonColors.whiteAlpha(0.85)
        case .primary: .white
        }
    }

    private var backgroundColor: Color {
        switch variant {
        case .base:    UnisonColors.whiteAlpha(hovering ? 0.12 : 0.06)
        case .primary: UnisonColors.whiteAlpha(hovering ? 0.22 : 0.16)
        }
    }

    private var borderColor: Color {
        switch variant {
        case .base:    UnisonColors.whiteAlpha(0.10)
        case .primary: UnisonColors.whiteAlpha(0.28)
        }
    }
}

