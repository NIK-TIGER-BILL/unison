import SwiftUI

/// Status of a single onboarding step. Hoisted out of `StepCard` so the
/// view's generic `Content` parameter doesn't cascade into call-site
/// type signatures (`StepCard<A>.Status` vs. `StepCard<B>.Status`).
public enum StepCardStatus: Equatable, Sendable {
    case pending
    case inProgress
    case done
    case error
}

/// Onboarding step card. Shows an icon plaque, title, status check (when
/// done), an optional `body` slot for inputs / hints, and an optional
/// `ErrorRow` underneath. DESIGN.md §5.20.
public struct StepCard<Content: View>: View {
    /// Re-exported for source-compatibility with earlier call sites.
    public typealias Status = StepCardStatus

    public let title: String
    public let icon: Image
    public let status: Status
    public let content: () -> Content

    @Environment(\.colorSchemeContrast) private var contrast

    public init(
        title: String,
        icon: Image,
        status: Status,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.status = status
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    // Inner icon plaque uses `ConcentricRectangle`, which
                    // picks its radius concentrically from the enclosing
                    // `containerShape(...)` per Apple's Liquid Glass
                    // guidance ("Applying Liquid Glass to custom views"):
                    //   "Help maintain a sense of visual continuity in
                    //    your interface by using rounded shapes that are
                    //    concentric to their containers."
                    ConcentricRectangle()
                        .fill(iconBackground)
                        .overlay(
                            ConcentricRectangle()
                                .stroke(iconBorder, lineWidth: borderWidth)
                        )
                        .frame(width: 36, height: 36)
                    icon
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(iconColor)
                        .accessibilityLabel(title)
                }
                // HIG Materials: vibrant `.primary` for the card title;
                // the icon glyph keeps its semantic colour (green when
                // done, coral on error, neutral otherwise).
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if status == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(UnisonColors.ready)
                        .accessibilityLabel("Готово")
                }
            }
            if status != .done {
                self.content()
                    .padding(.top, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(cardBackground)
        .overlay(
            ConcentricRectangle()
                .stroke(cardBorder, lineWidth: borderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Declare the card's container shape so nested
        // `ConcentricRectangle`s (icon plaque, inner buttons) can
        // pick their radius from the parent automatically.
        .containerShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var borderWidth: CGFloat {
        contrast == .increased ? 1.0 : 0.5
    }

    private var iconBackground: Color {
        switch status {
        case .done:  UnisonColors.ready.opacity(0.14)
        case .error: UnisonColors.error.opacity(0.12)
        default:     UnisonColors.whiteAlpha(0.06)
        }
    }

    private var iconBorder: Color {
        let boost: Double = contrast == .increased ? 1.8 : 1.0
        switch status {
        case .done:  return UnisonColors.ready.opacity(min(1.0, 0.35 * boost))
        case .error: return UnisonColors.error.opacity(min(1.0, 0.32 * boost))
        default:     return UnisonColors.whiteAlpha(min(1.0, 0.08 * boost * 1.5))
        }
    }

    private var iconColor: Color {
        switch status {
        case .done:  UnisonColors.ready
        case .error: UnisonColors.error
        default:     UnisonColors.whiteAlpha(0.7)
        }
    }

    private var cardBackground: Color {
        switch status {
        case .done:  UnisonColors.ready.opacity(0.04)
        case .error: UnisonColors.error.opacity(0.05)
        default:     Color.black.opacity(0.18)
        }
    }

    private var cardBorder: Color {
        let boost: Double = contrast == .increased ? 2.5 : 1.0
        switch status {
        case .done:  return UnisonColors.ready.opacity(min(1.0, 0.18 * boost))
        case .error: return UnisonColors.error.opacity(min(1.0, 0.28 * boost))
        default:     return UnisonColors.whiteAlpha(min(1.0, 0.06 * boost))
        }
    }
}

