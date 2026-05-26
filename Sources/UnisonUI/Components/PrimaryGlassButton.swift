import SwiftUI

/// Full-width primary action button. Hand-built rather than
/// `buttonStyle(.glassProminent)` because the latter renders as a
/// near-opaque dark fill on a dark popover — flat, low-contrast.
/// The recipe is glass + white linear-gradient tint + hairline rim
/// + top specular + drop shadow, all stacked under one `clipShape`.
public struct PrimaryGlassButton: View {
    public enum Variant: Equatable, Sendable {
        case standard
        case destructive
    }

    public let title: String
    public let icon: Image?
    public let variant: Variant
    public let isLoading: Bool
    public let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @SwiftUI.State private var isHovered = false

    public init(
        title: String,
        icon: Image? = nil,
        variant: Variant = .standard,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    Spinner(size: 12, lineWidth: 1.5)
                } else if let icon = icon {
                    icon
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .shadow(color: Color.black.opacity(0.25), radius: 0, x: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                ZStack {
                    shape
                        .fill(.clear)
                        .liquidGlass(shape: shape, interactive: true, highContrastHairline: false)
                    shape
                        .fill(tintGradient)
                    shape
                        .strokeBorder(borderColor, lineWidth: 0.5)
                        .blendMode(.plusLighter)
                    // Inset top specular — sells the raised glass look.
                    shape
                        .inset(by: 0.5)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.0)
                                ],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .blendMode(.plusLighter)
                }
            )
            .clipShape(shape)
            .shadow(color: shadowColor, radius: 6, x: 0, y: 4)
        }
        .buttonStyle(PressablePrimaryButtonStyle())
        .contentShape(shape)
        .disabled(isLoading)
        .brightness(isHovered ? 0.04 : 0)
        .scaleEffect(isHovered ? 1.015 : 1.0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var tintGradient: LinearGradient {
        switch variant {
        case .standard:
            LinearGradient(
                colors: [
                    Color.white.opacity(0.22),
                    Color.white.opacity(0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .destructive:
            LinearGradient(
                colors: [
                    Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255).opacity(0.42),
                    Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var borderColor: Color {
        switch variant {
        case .standard:
            Color.white.opacity(0.22)
        case .destructive:
            Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255).opacity(0.40)
        }
    }

    private var shadowColor: Color {
        switch variant {
        case .standard:
            Color.black.opacity(0.28)
        case .destructive:
            Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(0.32)
        }
    }
}

/// Exposes press state to scale the label on press — `.buttonStyle(.plain)`
/// doesn't surface `configuration.isPressed`.
private struct PressablePrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.08),
                value: configuration.isPressed
            )
    }
}
