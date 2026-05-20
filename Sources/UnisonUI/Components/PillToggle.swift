import SwiftUI

/// Pill-shaped on/off switch used in Settings. 34×19 track, 14×14 knob,
/// green-tinted when on. DESIGN.md §5.15.
public struct PillToggle: View {
    @Binding public var isOn: Bool

    public init(isOn: Binding<Bool>) {
        self._isOn = isOn
    }

    public var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // Track
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOn
                    ? UnisonColors.ready.opacity(0.32)
                    : UnisonColors.whiteAlpha(0.10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isOn
                                ? UnisonColors.ready.opacity(0.55)
                                : UnisonColors.whiteAlpha(0.12),
                            lineWidth: 0.5
                        )
                )
                .frame(width: 34, height: 19)
            // Knob
            Circle()
                .fill(LinearGradient(
                    colors: [.white, Color(red: 216 / 255, green: 216 / 255, blue: 218 / 255)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .shadow(color: .black.opacity(0.4), radius: 1.5, x: 0, y: 1)
                .frame(width: 14, height: 14)
                .padding(.horizontal, 1.5)
        }
        .frame(width: 34, height: 19)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        }
    }
}

