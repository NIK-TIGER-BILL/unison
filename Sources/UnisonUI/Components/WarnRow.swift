import SwiftUI

/// Amber warning row used in the popover ("Выбран одинаковый язык").
/// Animates in/out via opacity + slight Y-offset. DESIGN.md §5.11.
struct WarnRow: View {
    let message: String
    let isVisible: Bool

    init(message: String, isVisible: Bool = true) {
        self.message = message
        self.isVisible = isVisible
    }

    var body: some View {
        Group {
            if isVisible {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(UnisonColors.warn)
                    Text(message)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(red: 255 / 255, green: 220 / 255, blue: 170 / 255).opacity(0.95))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(UnisonColors.warn.opacity(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(UnisonColors.warn.opacity(0.28), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
        .animation(UnisonAnimations.state, value: isVisible)
    }
}
