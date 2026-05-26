import SwiftUI

/// Transcript-window control pill. Status dot + timer + gear +
/// Скрыть/Показать + stop, sitting on a single Liquid Glass capsule.
/// Doubles as the drag handle for the host panel (see CLAUDE.md).
///
/// `interactive: false` on the glass is deliberate — `Glass.interactive()`
/// installs a hit-testable surface that intercepts mouse-down before
/// it reaches the `WindowDragHandle` background and kills drag.
public struct ControlPill: View {
    public let isActive: Bool
    public let elapsedLabel: String
    public let isHidden: Bool
    public let isSettingsOpen: Bool
    public let isTestMode: Bool
    public let onToggleSettings: () -> Void
    public let onToggleHidden: () -> Void
    public let onStop: () -> Void

    public init(
        isActive: Bool,
        elapsedLabel: String,
        isHidden: Bool,
        isSettingsOpen: Bool,
        isTestMode: Bool = false,
        onToggleSettings: @escaping () -> Void,
        onToggleHidden: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.elapsedLabel = elapsedLabel
        self.isHidden = isHidden
        self.isSettingsOpen = isSettingsOpen
        self.isTestMode = isTestMode
        self.onToggleSettings = onToggleSettings
        self.onToggleHidden = onToggleHidden
        self.onStop = onStop
    }

    public var body: some View {
        let hideShowLabel = isHidden ? "Показать транскрипт" : "Скрыть транскрипт"
        return HStack(spacing: 6) {
            // Hit-test transparent so the WindowDragHandle below
            // receives clicks on the dot / timer / separator.
            // `.allowsHitTesting(false)` only suppresses pointer
            // hit-tests; VoiceOver still picks up the labels.
            Group {
                StatusDot(state: dotState, size: 6)
                    .padding(.leading, 8)
                Text(elapsedLabel)
                    .font(UnisonFonts.mono(10.5))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Прошло: \(elapsedLabel)")
                sep
            }
            .allowsHitTesting(false)
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
        .background(WindowDragHandle())
        .liquidGlass(shape: Capsule())
    }

    private var dotState: StatusDot.State {
        if !isActive { return .ready }
        return isTestMode ? .warn : .active
    }

    private var sep: some View {
        Rectangle()
            .fill(UnisonColors.whiteAlpha(0.14))
            .frame(width: 0.5, height: 13)
            .padding(.horizontal, 3)
    }
}
