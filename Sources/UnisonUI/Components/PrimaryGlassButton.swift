import SwiftUI

/// Full-width primary action button. Two variants:
/// - `.standard` — white-glass gradient ("Начать перевод", "Готово").
/// - `.destructive` — coral gradient for Stop ("Остановить перевод").
/// DESIGN.md §5.4.
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

    @Environment(\.isEnabled) private var isEnabled
    @SwiftUI.State private var hovering = false
    @SwiftUI.State private var pressed = false
    @SwiftUI.State private var spinAngle = 0.0

    public var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    spinner
                } else if let icon = icon {
                    icon
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(textColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(backgroundGradient)
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .shadow(
                color: shadowColor,
                radius: hovering ? 8 : 6,
                x: 0,
                y: hovering ? 6 : 4
            )
            .scaleEffect(pressed && isEnabled ? 0.98 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(UnisonAnimations.hover, value: hovering)
        .animation(UnisonAnimations.press, value: pressed)
    }

    private var textColor: Color {
        isEnabled ? .white : UnisonColors.whiteAlpha(0.4)
    }

    private var borderColor: Color {
        switch variant {
        case .standard:
            isEnabled ? UnisonColors.whiteAlpha(0.22) : UnisonColors.whiteAlpha(0.10)
        case .destructive:
            Color(red: 1.0, green: 110 / 255, blue: 130 / 255).opacity(0.40)
        }
    }

    private var shadowColor: Color {
        switch variant {
        case .standard:
            Color.black.opacity(hovering ? 0.35 : 0.28)
        case .destructive:
            Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(hovering ? 0.42 : 0.32)
        }
    }

    @ViewBuilder
    private var backgroundGradient: some View {
        switch variant {
        case .standard:
            LinearGradient(
                colors: hovering
                    ? [UnisonColors.whiteAlpha(0.30), UnisonColors.whiteAlpha(0.12)]
                    : [UnisonColors.whiteAlpha(0.22), UnisonColors.whiteAlpha(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        case .destructive:
            LinearGradient(
                colors: hovering
                    ? [
                        Color(red: 1.0, green: 130 / 255, blue: 150 / 255).opacity(0.55),
                        Color(red: 230 / 255, green: 75 / 255, blue: 105 / 255).opacity(0.38),
                    ]
                    : [
                        Color(red: 1.0, green: 110 / 255, blue: 130 / 255).opacity(0.42),
                        Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(0.28),
                    ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.white, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(spinAngle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    spinAngle = 360
                }
            }
    }
}

