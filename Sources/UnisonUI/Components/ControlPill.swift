import SwiftUI

/// Transcript-window control pill: status dot + timer + settings gear +
/// Скрыть/Показать text button + stop icon. Draggable via the panel's
/// host window (UnisonApp sets `isMovableByWindowBackground`).
/// DESIGN.md §5.18.
public struct ControlPill: View {
    public let isActive: Bool
    public let elapsedLabel: String
    public let isHidden: Bool
    public let isSettingsOpen: Bool
    public let onToggleSettings: () -> Void
    public let onToggleHidden: () -> Void
    public let onStop: () -> Void

    public init(
        isActive: Bool,
        elapsedLabel: String,
        isHidden: Bool,
        isSettingsOpen: Bool,
        onToggleSettings: @escaping () -> Void,
        onToggleHidden: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.elapsedLabel = elapsedLabel
        self.isHidden = isHidden
        self.isSettingsOpen = isSettingsOpen
        self.onToggleSettings = onToggleSettings
        self.onToggleHidden = onToggleHidden
        self.onStop = onStop
    }

    public var body: some View {
        HStack(spacing: 6) {
            StatusDot(state: isActive ? .active : .ready, size: 6)
                .padding(.leading, 8)
            Text(elapsedLabel)
                .font(UnisonFonts.mono(10.5))
                .tracking(0.4)
                .foregroundStyle(UnisonColors.whiteAlpha(0.7))
            sep
            Button(action: onToggleSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(isSettingsOpen ? .white : UnisonColors.whiteAlpha(0.65))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(isSettingsOpen
                            ? UnisonColors.whiteAlpha(0.14)
                            : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            Button(action: onToggleHidden) {
                Text(isHidden ? "Показать" : "Скрыть")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(UnisonColors.whiteAlpha(0.75))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(UnisonColors.whiteAlpha(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(UnisonColors.whiteAlpha(0.08), lineWidth: 0.5)
                            )
                    )
            }
            .buttonStyle(.plain)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(UnisonColors.whiteAlpha(0.65))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .padding(.vertical, 6)
        .liquidGlass(cornerRadius: 999)
    }

    private var sep: some View {
        Rectangle()
            .fill(UnisonColors.whiteAlpha(0.14))
            .frame(width: 0.5, height: 13)
            .padding(.horizontal, 3)
    }
}

