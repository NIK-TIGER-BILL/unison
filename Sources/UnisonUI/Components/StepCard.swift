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
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(iconBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(iconBorder, lineWidth: 0.5)
                        )
                        .frame(width: 36, height: 36)
                    icon
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                if status == .done {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(UnisonColors.ready)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(cardBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var iconBackground: Color {
        switch status {
        case .done:  UnisonColors.ready.opacity(0.14)
        case .error: UnisonColors.error.opacity(0.12)
        default:     UnisonColors.whiteAlpha(0.06)
        }
    }

    private var iconBorder: Color {
        switch status {
        case .done:  UnisonColors.ready.opacity(0.35)
        case .error: UnisonColors.error.opacity(0.32)
        default:     UnisonColors.whiteAlpha(0.08)
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
        switch status {
        case .done:  UnisonColors.ready.opacity(0.18)
        case .error: UnisonColors.error.opacity(0.28)
        default:     UnisonColors.whiteAlpha(0.06)
        }
    }
}

