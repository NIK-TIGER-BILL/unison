import SwiftUI

/// Single Settings row: leading label area (icon + title + optional hint
/// underneath) and trailing value control (dropdown / toggle / slider / etc).
/// DESIGN.md §5.10.
///
/// The `trailing` view is provided by the caller — `SettingsRow` only
/// handles layout, alignment, and the 0.5pt separator with the previous row
/// when used inside a `VStack(spacing: 0)`.
public struct SettingsRow<Trailing: View>: View {
    public let title: String
    public let icon: Image?
    public let hint: String?
    public let trailing: () -> Trailing

    public init(
        _ title: String,
        icon: Image? = nil,
        hint: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.icon = icon
        self.hint = hint
        self.trailing = trailing
    }

    public var body: some View {
        HStack(alignment: hint == nil ? .center : .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    if let icon = icon {
                        icon
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(UnisonColors.whiteAlpha(0.55))
                            .frame(width: 13, height: 13)
                    }
                    Text(title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.88))
                }
                if let hint = hint {
                    Text(hint)
                        .font(.system(size: 11))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
        .overlay(alignment: .top) {
            Divider()
                .frame(height: 0.5)
                .overlay(UnisonColors.whiteAlpha(0.05))
        }
    }
}

