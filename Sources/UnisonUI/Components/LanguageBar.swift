import SwiftUI
import UnisonDomain

/// "Я говорю / Слушаю" popover bar. Two `LanguageSideButton`s with an
/// arrow between. Tapping a side fires `onOpenDropdown(side)` so the
/// parent owns the dropdown's presentation (overlay vs popover).
/// DESIGN.md §5.9.
public struct LanguageBar: View {
    public enum Side: Equatable, Sendable {
        case mine
        case peer
    }

    public let pair: LanguagePair
    public let openSide: Side?
    public let isWarning: Bool
    public let onOpenDropdown: (Side) -> Void

    public init(
        pair: LanguagePair,
        openSide: Side?,
        isWarning: Bool,
        onOpenDropdown: @escaping (Side) -> Void
    ) {
        self.pair = pair
        self.openSide = openSide
        self.isWarning = isWarning
        self.onOpenDropdown = onOpenDropdown
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            LanguageSideButton(
                label: "Я говорю",
                language: pair.mine,
                isOpen: openSide == .mine,
                alignment: .leading,
                onTap: { onOpenDropdown(.mine) }
            )
            arrow
            LanguageSideButton(
                label: "Слушаю",
                language: pair.peer,
                isOpen: openSide == .peer,
                alignment: .trailing,
                onTap: { onOpenDropdown(.peer) }
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(isWarning ? UnisonColors.warn.opacity(0.08) : Color.black.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            isWarning ? UnisonColors.warn.opacity(0.30) : .clear,
                            lineWidth: 0.5
                        )
                )
        )
        .animation(UnisonAnimations.state, value: isWarning)
    }

    private var arrow: some View {
        // HIG Materials: vibrant `.secondary` for the bidirectional
        // swap icon between the two language sides.
        Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)
    }
}

/// Tappable side of `LanguageBar` showing label + flag + language name +
/// disclosure chevron.
public struct LanguageSideButton: View {
    public let label: String
    public let language: Language
    public let isOpen: Bool
    public let alignment: HorizontalAlignment
    public let onTap: () -> Void

    public init(
        label: String,
        language: Language,
        isOpen: Bool,
        alignment: HorizontalAlignment,
        onTap: @escaping () -> Void
    ) {
        self.label = label
        self.language = language
        self.isOpen = isOpen
        self.alignment = alignment
        self.onTap = onTap
    }

    @SwiftUI.State private var pressed = false
    @SwiftUI.State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        Button(action: onTap) {
            VStack(alignment: alignment, spacing: 4) {
                // HIG Materials: the tracked-uppercase "Я ГОВОРЮ" /
                // "СЛУШАЮ" caption is intentionally faded (`.tertiary`),
                // the language name is the primary value text, and the
                // chevron flips from `.tertiary` → `.primary` when its
                // dropdown is open.
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    if alignment == .leading {
                        // Decorative — VoiceOver reads the language
                        // name from the composite accessibilityLabel
                        // on the Button below.
                        FlagText(language.flagEmoji)
                    }
                    Text(language.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                    if alignment == .trailing {
                        FlagText(language.flagEmoji)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(isOpen ? .primary : .tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundFill)
            )
            .scaleEffect(pressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label): \(language.displayName)")
        .help("\(label): \(language.displayName)")
        .onHover { isHovered = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded   { _ in pressed = false }
        )
        .animation(UnisonAnimations.press.reduceMotion(reduceMotion), value: pressed)
        .animation(UnisonAnimations.dropdown.reduceMotion(reduceMotion), value: isOpen)
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }

    /// Three-way background: pressed > hovered > rest.
    /// The press tint is brighter than the hover tint so the active
    /// state is still distinguishable when the pointer is already on
    /// the button.
    private var backgroundFill: Color {
        if pressed {
            return UnisonColors.whiteAlpha(0.10)
        }
        if isHovered {
            return UnisonColors.whiteAlpha(0.06)
        }
        return Color.clear
    }
}

