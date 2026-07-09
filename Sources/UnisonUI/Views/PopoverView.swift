import AppKit
import SwiftUI
import UnisonDomain

/// Menubar popover — the primary control surface of Unison.
/// 340pt wide rounded glass card. Top row holds the TEST button +
/// gear; below: Call/Listen toggle, language pickers, start/stop
/// primary button + `mm:ss` timer.
public struct PopoverView: View {
    @Bindable var vm: PopoverViewModel
    let onOpenSettings: () -> Void
    let onShowHelp: () -> Void
    let onShowDiagnostic: () -> Void

    @SwiftUI.State private var isTestHovered = false
    @SwiftUI.State private var isSwapHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        vm: PopoverViewModel,
        onOpenSettings: @escaping () -> Void = {},
        onShowHelp: @escaping () -> Void = {},
        onShowDiagnostic: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenSettings = onOpenSettings
        self.onShowHelp = onShowHelp
        self.onShowDiagnostic = onShowDiagnostic
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
            if vm.startBlockedReason == .noAppsToTranslate {
                WarnRow(message: "Выберите приложения для перевода")
            }
            primaryButton
            if vm.state.isActive {
                timer
            }
            // Timer + Stop stay visible across `.translating`/`.reconnecting`
            // flapping so the UI doesn't bounce; only this thin hint swaps in.
            // Covers reconnect, .paused (network lost / awaiting), and the
            // .translating × {slow, recovering} sub-states. Empty string
            // collapses the row entirely so we don't reserve vertical space.
            if !vm.statusText.isEmpty {
                statusHint
            }
            if let reason = vm.state.errorValue {
                ErrorRow(
                    title: "Не удалось запустить",
                    detail: PopoverViewModel.userMessage(for: reason, model: vm.settings.translationModel),
                    action: reason == .audioCaptureDenied
                        ? .openSettings(label: "Открыть Настройки") {
                            // macOS 14.4+ split AudioCapture into per-service panes; the
                            // Process Tap permission lives under "Screen & System Audio
                            // Recording → System Audio Recording Only".
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                            )
                        }
                        : .retry(label: "Повторить") {
                            Task { await vm.start() }
                        }
                )
                HStack {
                    Spacer()
                    Button("Подробности…", action: onShowDiagnostic)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.7))
                }
            }
        }
        .padding(16)
    }

    // MARK: - Sections

    private var topRow: some View {
        HStack(spacing: 8) {
            StatusDot(state: vm.statusDotState)
            Text("Unison")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.26)
                .foregroundStyle(.primary)
            // Self-test runs `mic → translate → speakers` locally.
            // Disabled while a real session is active so the user
            // can't stomp on a live call.
            Button(action: {
                Task { @MainActor in await vm.startTest() }
            }) {
                Text("TEST")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .strokeBorder(
                                UnisonColors.whiteAlpha(isTestHovered ? 0.40 : 0.22),
                                lineWidth: 0.5
                            )
                    )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(vm.state.isActive)
            .opacity(vm.state.isActive ? 0.4 : 1.0)
            .help("Проверка перевода")
            .accessibilityLabel("Проверка перевода")
            .onHover { hovering in isTestHovered = hovering }
            Spacer()
            IconButton(label: "Как пользоваться", action: onShowHelp) {
                Image(systemName: "questionmark")
                    .font(.system(size: 12, weight: .regular))
            }
            IconButton(label: "Настройки", action: onOpenSettings) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .regular))
            }
        }
    }

    /// Locked while a session is active, mirroring `languageBar`: the
    /// running session keeps the mode it was started with, so flipping
    /// the segment mid-session would silently lie about what's running.
    private var modeToggle: some View {
        let locked = vm.state.isActive
        return SegmentedToggle(
            // Route through the VM mutator (not a direct settings write)
            // so the pick persists across restarts.
            selection: Binding(
                get: { vm.settings.sessionMode },
                set: { vm.updateSessionMode($0) }
            ),
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
                )
            ]
        )
        .disabled(locked)
        .opacity(locked ? 0.55 : 1.0)
        .animation(UnisonAnimations.state, value: locked)
    }

    /// Two `Picker(.menu)` columns with a swap arrow between them.
    /// Disabled while a session is active — `updateLanguagePair`
    /// doesn't touch the running orchestrator, so changing the pair
    /// mid-session would silently lie about the audio direction.
    private var languageBar: some View {
        let locked = vm.state.isActive
        return HStack(alignment: .center, spacing: 0) {
            languagePicker(
                caption: "Я говорю",
                alignment: .leading,
                selection: Binding(
                    get: { vm.settings.languagePair.mine },
                    set: { lang in pick(lang, for: .mine) }
                )
            )
            // Tappable swap: flip the two languages in place. The swap
            // itself is instant (no animation, per design); only the
            // hover highlight fades. The whole `languageBar` is
            // `.disabled(locked)` during an active session, so this
            // button inherits that lock and can't fire mid-call.
            Button {
                vm.updateLanguagePair(vm.settings.languagePair.swapped)
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            // `&& !locked`: a disabled bar must not paint a
                            // hover highlight (see `.pointerStyle`/`.onHover`
                            // note below). Also covers the hover-then-lock
                            // case where no exit event fires.
                            .fill(UnisonColors.whiteAlpha(isSwapHovered && !locked ? 0.08 : 0))
                    )
                    // Claim the full rounded-square as the tap surface,
                    // not just the glyph — otherwise only the thin arrow
                    // pixels would respond to clicks.
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            // `.disabled` (inherited from `languageBar`) blocks the tap but
            // NOT `.onHover`/`.pointerStyle` — those are region-based. Gate
            // both on `locked` so a session-locked bar shows neither the
            // link cursor nor a highlight (which would read as clickable).
            .pointerStyle(locked ? nil : .link)
            .onHover { isSwapHovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSwapHovered)
            .padding(.horizontal, 6)
            .accessibilityLabel("Поменять языки местами")
            // Empty tooltip while locked: AppKit shows `.help` even on a
            // disabled control, which would imply the arrow is actionable
            // mid-session. Mirrors the `.pointerStyle`/highlight gating above.
            .help(locked ? "" : "Поменять языки местами")
            // Drop the arrow to line up with the picker BOX centre (not the
            // whole column, whose caption sits above). Uses `.offset` — a
            // visual-only shift — instead of `.alignmentGuide`: a custom
            // center guide on this 26pt button pushes the button's bottom
            // past the pickers' bounds, which sends the popover's
            // `NSHostingView.updateAnimatedWindowSize` into infinite
            // recursion on macOS 26.5.1 (stack overflow at open). `.offset`
            // doesn't touch the measured size, so the window auto-size stays
            // stable.
            .offset(y: 9)
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
        .disabled(locked)
        .opacity(locked ? 0.55 : 1.0)
        .animation(UnisonAnimations.state, value: vm.isLanguagePairValid)
        .animation(UnisonAnimations.state, value: locked)
    }

    private func languagePicker(
        caption: String,
        alignment: HorizontalAlignment,
        selection: Binding<Language>
    ) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Picker("", selection: selection) {
                // Both sides of `LanguagePair` are restricted to the
                // selected engine's supported output targets.
                ForEach(vm.settings.translationModel.supportedTargets, id: \.self) { lang in
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
        // TimelineView ticks the label so the VM stays free of timers.
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(vm.elapsedSecondsString)
                .font(UnisonFonts.mono(11.5))
                .tracking(0.92)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(maxWidth: .infinity)
        }
    }

    private var statusHint: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
            Text(vm.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
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
    static let width: CGFloat = 340
}
