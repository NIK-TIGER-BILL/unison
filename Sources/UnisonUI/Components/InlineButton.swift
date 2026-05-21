import SwiftUI

/// Small bordered button used inline in Settings rows. Two variants
/// per DESIGN.md §5.16:
/// - `.base` — native `.buttonStyle(.glass)` (translucent, secondary).
/// - `.primary` — native `.buttonStyle(.glassProminent)` (brighter).
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

    @ViewBuilder
    public var body: some View {
        switch variant {
        case .base:
            label
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(isLoading)
        case .primary:
            label
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(isLoading)
        }
    }

    private var label: Button<some View> {
        Button(action: action) {
            HStack(spacing: 5) {
                if isLoading {
                    Spinner(size: 10, lineWidth: 1.3)
                } else if let icon = icon {
                    icon
                        .font(.system(size: 10, weight: .regular))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
        }
    }
}
