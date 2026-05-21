import SwiftUI

/// Full-width primary action button. Native Liquid Glass on macOS 26:
/// `.buttonStyle(.glassProminent)` for the primary surface; `.tint(...)`
/// switches it to a destructive red. DESIGN.md §5.4.
///
/// Two variants:
/// - `.standard` — neutral white-glass (Start translating, Done).
/// - `.destructive` — coral-tinted (Stop translating).
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

    public var body: some View {
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
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(tint)
        .controlSize(.large)
        .buttonBorderShape(.roundedRectangle(radius: 13))
        .disabled(isLoading)
    }

    /// `nil` lets the system pick the neutral prominent material; a
    /// coral tint flips the button to the destructive Liquid-Glass-Red.
    private var tint: Color? {
        switch variant {
        case .standard:    nil
        case .destructive: Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255)
        }
    }
}
