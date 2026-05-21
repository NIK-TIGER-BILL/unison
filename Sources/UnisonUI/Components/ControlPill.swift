import SwiftUI

/// Transcript-window control pill: status dot + timer + settings gear +
/// Скрыть/Показать text button + stop icon. Draggable via the panel's
/// host window (UnisonApp sets `isMovableByWindowBackground`).
/// DESIGN.md §5.18.
///
/// Single Liquid Glass capsule — all internal controls sit on top
/// of one glass surface (no nested glass). Uses Apple's native
/// `.glassEffect(.regular.interactive(), in: Capsule())` per the
/// official Liquid Glass guidance ("Applying Liquid Glass to custom
/// views"):
///   "Add `Glass.interactive(_:)` to custom components to make them
///    react to touch and pointer interactions. This applies the same
///    responsive and fluid reactions that the `glass` button style
///    provides."
public struct ControlPill: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        let hideShowLabel = isHidden ? "Показать транскрипт" : "Скрыть транскрипт"
        return HStack(spacing: 6) {
            StatusDot(state: isActive ? .active : .ready, size: 6)
                .padding(.leading, 8)
            // HIG Materials: vibrant `.secondary` for the mono timer
            // and other muted controls on the glass capsule; the active
            // gear icon flips to `.primary` to signal selection.
            Text(elapsedLabel)
                .font(UnisonFonts.mono(10.5))
                .tracking(0.4)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Прошло: \(elapsedLabel)")
            sep
            Button(action: onToggleSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12))
                    .foregroundStyle(isSettingsOpen ? .primary : .secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        Circle().fill(isSettingsOpen
                            ? UnisonColors.whiteAlpha(0.14)
                            : Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Настройки транскрипта")
            .help("Настройки транскрипта")
            Button(action: onToggleHidden) {
                Text(isHidden ? "Показать" : "Скрыть")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
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
            .accessibilityLabel(hideShowLabel)
            .help(hideShowLabel)
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
            .accessibilityLabel("Остановить перевод")
            .help("Остановить перевод")
        }
        .padding(.vertical, 6)
        .glassEffect(
            reduceTransparency ? .identity : .regular.interactive(),
            in: Capsule()
        )
    }

    private var sep: some View {
        Rectangle()
            .fill(UnisonColors.whiteAlpha(0.14))
            .frame(width: 0.5, height: 13)
            .padding(.horizontal, 3)
    }
}

