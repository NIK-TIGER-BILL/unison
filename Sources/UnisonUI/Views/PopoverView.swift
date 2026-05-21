import SwiftUI
import UnisonDomain

/// Menubar popover — the primary control surface of Unison.
///
/// Strictly mirrors `design/popover-final/index.html`:
/// - 340pt wide, 16pt padding, `.liquidGlass(cornerRadius: 24)` background.
/// - Top row: `StatusDot` + brand text + gear `IconButton`.
/// - `SegmentedToggle` for Call/Listen, bound to `vm.settings.sessionMode`.
/// - Two native `Picker`s with `.pickerStyle(.menu)` for "Я говорю" and
///   "Слушаю". The opened menu is an `NSMenu` rendered above the
///   popover by AppKit, so it can never be clipped by the popover
///   bounds — the previous custom overlay-based dropdown had exactly
///   that bug.
/// - `WarnRow` when the same language is selected on both sides.
/// - `PrimaryGlassButton` toggling start/stop; coral while translating.
/// - `mm:ss` timer (mono) below the button while translating.
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

    public var body: some View {
        content
            .frame(width: PopoverLayout.width)
            .liquidGlass(cornerRadius: 24)
            .frame(width: PopoverLayout.width)
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
            IconButton(label: "Настройки", action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .regular))
            }
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

    /// "Я говорю / Слушаю" — two native menu pickers separated by the
    /// directional swap arrow. Each `Picker(.menu)` renders as a
    /// macOS pop-up button; the opened menu is a system `NSMenu`
    /// drawn over the popover, so it never gets clipped (which is the
    /// whole point of replacing the previous overlay-based dropdown).
    private var languageBar: some View {
        HStack(alignment: .center, spacing: 0) {
            languagePicker(
                caption: "Я говорю",
                alignment: .leading,
                selection: Binding(
                    get: { vm.settings.languagePair.mine },
                    set: { lang in pick(lang, for: .mine) }
                )
            )
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            languagePicker(
                caption: "Слушаю",
                alignment: .trailing,
                selection: Binding(
                    get: { vm.settings.languagePair.peer },
                    set: { lang in pick(lang, for: .peer) }
                )
            )
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(vm.isLanguagePairValid
                      ? Color.black.opacity(0.16)
                      : UnisonColors.warn.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(
                            vm.isLanguagePairValid ? .clear : UnisonColors.warn.opacity(0.30),
                            lineWidth: 0.5
                        )
                )
        )
        .animation(UnisonAnimations.state, value: vm.isLanguagePairValid)
    }

    /// One side of the language bar — a small caption ("Я ГОВОРЮ" /
    /// "СЛУШАЮ") above a native `Picker(.menu)`. The picker is
    /// `labelsHidden()` so SwiftUI uses our caption as the only label,
    /// and `.tint(.primary)` keeps it neutral on the glass background.
    private func languagePicker(
        caption: String,
        alignment: HorizontalAlignment,
        selection: Binding<Language>
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(caption)
                .font(.system(size: 9.5, weight: .medium))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(.tertiary)
            Picker("", selection: selection) {
                ForEach(Language.allCases, id: \.self) { lang in
                    Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(.primary)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
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
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private enum Side { case mine, peer }

    private func pick(_ lang: Language, for side: Side) {
        let current = vm.settings.languagePair
        let pair: LanguagePair = switch side {
        case .mine: LanguagePair(mine: lang, peer: current.peer)
        case .peer: LanguagePair(mine: current.mine, peer: lang)
        }
        vm.updateLanguagePair(pair)
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
