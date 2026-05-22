import SwiftUI

/// Coral error row used in onboarding step cards. Has a title (bold) and
/// optional detail, plus an optional inline action button.
/// DESIGN.md §5.12.
public struct ErrorRow: View {
    public enum Action {
        case retry(label: String, handler: () -> Void)
        case openSettings(label: String, handler: () -> Void)
    }

    public let title: String
    public let detail: String?
    public let action: Action?

    public init(title: String, detail: String? = nil, action: Action? = nil) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(UnisonColors.error)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                if let detail = detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 255 / 255, green: 200 / 255, blue: 210 / 255).opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if let action = action {
                ErrorActionButton(action: action)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(UnisonColors.error.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(UnisonColors.error.opacity(0.22), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Inline coral action button for `ErrorRow` ("Повторить" /
/// "Открыть Настройки"). Hover lifts brightness + scale so the affordance
/// is visible against the coral row background — the bare `.plain`
/// button style provides none. Extracted from `ErrorRow` so it can carry
/// its own `@State` for the hover flag.
private struct ErrorActionButton: View {
    let action: ErrorRow.Action

    @SwiftUI.State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let (label, handler): (String, () -> Void) = {
            switch action {
            case .retry(let label, let handler):        return (label, handler)
            case .openSettings(let label, let handler): return (label, handler)
            }
        }()
        Button(action: handler) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11.5))
                    .lineLimit(1)
                if case .openSettings = action {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .foregroundStyle(UnisonColors.error)
            .background(UnisonColors.error.opacity(isHovered ? 0.14 : 0.08))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(UnisonColors.error.opacity(isHovered ? 0.34 : 0.20), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // Keep the button's natural width so its label is never
            // truncated when the error message wraps to multiple lines.
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

