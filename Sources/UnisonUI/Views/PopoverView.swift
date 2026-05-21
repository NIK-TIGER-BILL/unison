import SwiftUI
import UnisonDomain

/// Menubar popover — the primary control surface of Unison.
///
/// Strictly mirrors `design/popover-final/index.html`:
/// - 340pt wide, 16pt padding, `.liquidGlass(cornerRadius: 24)` background.
/// - Top row: `StatusDot` + brand text + gear `IconButton`.
/// - `SegmentedToggle` for Call/Listen, bound to `vm.settings.sessionMode`.
/// - `LanguageBar` driving two `LanguagePickerDropdown`s (mine/peer), each
///   anchored beneath its side.
/// - `WarnRow` when the same language is selected on both sides.
/// - `PrimaryGlassButton` toggling start/stop; coral while translating.
/// - `mm:ss` timer (mono) below the button while translating.
///
/// The dropdown is rendered as an overlay outside the clipped glass panel
/// so it can extend past the panel's rounded edges. Its position is
/// measured via a `PreferenceKey` capturing the `LanguageBar`'s frame in
/// a named coordinate space, so the dropdown follows layout changes.
public struct PopoverView: View {
    @Bindable var vm: PopoverViewModel
    let onOpenSettings: () -> Void

    public init(
        vm: PopoverViewModel,
        onOpenSettings: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenSettings = onOpenSettings
    }

    /// Which language-picker dropdown (if any) is currently open.
    @SwiftUI.State private var openSide: LanguageBar.Side? = nil

    /// Frame of the language bar, captured in the "popover" coordinate
    /// space. Used to anchor the dropdown overlay below the bar.
    @SwiftUI.State private var langBarFrame: CGRect = .zero

    public var body: some View {
        ZStack(alignment: .topLeading) {
            content
                .frame(width: PopoverLayout.width)
                .liquidGlass(cornerRadius: 24)

            if let side = openSide {
                dropdownOverlay(for: side)
                    .zIndex(10)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: PopoverLayout.width)
        .coordinateSpace(name: PopoverLayout.coordinateSpace)
        .onPreferenceChange(LangBarFrameKey.self) { newFrame in
            langBarFrame = newFrame
        }
        // Tap outside dismisses any open dropdown.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    closeDropdown()
                }
        )
        .animation(UnisonAnimations.dropdown, value: openSide)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 12) {
            topRow
            modeToggle
            languageBar
            if !vm.isLanguagePairValid {
                WarnRow(message: "Выбран одинаковый язык")
            }
            primaryButton
            if vm.state.isActive {
                timer
            }
        }
        .padding(16)
    }

    // MARK: - Sections

    private var topRow: some View {
        HStack(spacing: 8) {
            StatusDot(state: vm.statusKind.dotState)
            // HIG Materials: use vibrant `.primary` foreground so the
            // system handles contrast across light/dark and Increase
            // Contrast / Reduce Transparency on the glass background.
            Text("Unison")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.26)
                .foregroundStyle(.primary)
            Spacer()
            IconButton(action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .regular))
            }
            .accessibilityLabel("Настройки")
        }
    }

    private var modeToggle: some View {
        SegmentedToggle(
            selection: $vm.settings.sessionMode,
            segments: [
                .init(
                    id: "call",
                    title: "Call",
                    icon: Image(systemName: "phone.fill"),
                    mode: .call
                ),
                .init(
                    id: "listen",
                    title: "Listen",
                    icon: Image(systemName: "headphones"),
                    mode: .listen
                ),
            ]
        )
    }

    private var languageBar: some View {
        LanguageBar(
            pair: vm.settings.languagePair,
            openSide: openSide,
            isWarning: !vm.isLanguagePairValid,
            onOpenDropdown: { side in
                toggleSide(side)
            }
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LangBarFrameKey.self,
                    value: proxy.frame(in: .named(PopoverLayout.coordinateSpace))
                )
            }
        )
    }

    private var primaryButton: some View {
        PrimaryGlassButton(
            title: vm.primaryButtonTitle,
            icon: primaryButtonImage,
            variant: vm.state.isActive ? .destructive : .standard,
            action: { Task { await togglePrimary() } }
        )
        .disabled(!vm.state.isActive && !vm.canStartStrict)
    }

    private var primaryButtonImage: Image {
        switch vm.primaryButtonIcon {
        case .play: Image(systemName: "play.fill")
        case .stop: Image(systemName: "stop.fill")
        }
    }

    private var timer: some View {
        // Drive the ticking purely from the view via TimelineView so the
        // ViewModel stays free of timers (per plan §3.1).
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(vm.elapsedSecondsString)
                .font(UnisonFonts.mono(11.5))
                .tracking(0.92)
                // HIG Materials: vibrant `.secondary` keeps the mono
                // timer subdued but legible over the glass panel.
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Dropdown overlay

    @ViewBuilder
    private func dropdownOverlay(for side: LanguageBar.Side) -> some View {
        let dropdownWidth: CGFloat = 220
        let originX: CGFloat = {
            switch side {
            case .mine: return langBarFrame.minX
            case .peer: return langBarFrame.maxX - dropdownWidth
            }
        }()
        let originY: CGFloat = langBarFrame.maxY + 6

        LanguagePickerDropdown(
            selection: Binding(
                get: {
                    switch side {
                    case .mine: vm.settings.languagePair.mine
                    case .peer: vm.settings.languagePair.peer
                    }
                },
                set: { newLang in
                    pick(newLang, for: side)
                }
            ),
            onPick: { lang in pick(lang, for: side) },
            onCancel: { closeDropdown() }
        )
        .offset(x: originX, y: originY)
    }

    // MARK: - Actions

    private func toggleSide(_ side: LanguageBar.Side) {
        withAnimation(UnisonAnimations.dropdown) {
            openSide = (openSide == side) ? nil : side
        }
    }

    private func closeDropdown() {
        if openSide != nil {
            withAnimation(UnisonAnimations.dropdown) {
                openSide = nil
            }
        }
    }

    private func pick(_ lang: Language, for side: LanguageBar.Side) {
        let current = vm.settings.languagePair
        let pair: LanguagePair = switch side {
        case .mine: LanguagePair(mine: lang, peer: current.peer)
        case .peer: LanguagePair(mine: current.mine, peer: lang)
        }
        vm.updateLanguagePair(pair)
        closeDropdown()
    }

    private func togglePrimary() async {
        if vm.state.isActive {
            await vm.stop()
        } else {
            await vm.start()
        }
    }
}

// MARK: - Layout constants

private enum PopoverLayout {
    /// DESIGN §4.3: total popover width is exactly 340pt.
    static let width: CGFloat = 340
    /// Coordinate-space name used to anchor the dropdown overlay.
    static let coordinateSpace: String = "popover"
}

// MARK: - PreferenceKey

private struct LangBarFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - StatusKind → StatusDot.State

private extension PopoverViewModel.StatusKind {
    var dotState: StatusDot.State {
        switch self {
        case .ready: .ready
        case .active: .active
        case .warn:  .warn
        case .error: .error
        }
    }
}
