import SwiftUI
import UnisonDomain

/// Liquid-glass onboarding window — the first thing the user sees when
/// they launch Unison without all three prerequisites in place.
///
/// Strictly mirrors `design/onboarding-final/index.html`:
/// - Centred Unison-logo plate (56×56 glass) + "Установка" title.
/// - Three stacked `StepCard`s (BlackHole / Microphone / OpenAI key).
/// - Per-card check badge appears once the step is done; the action
///   button itself swaps to a spinner while a step is in progress.
/// - Coral `ErrorRow` underneath the action when the step fails.
/// - Footer with `X / 3 готово` progress and a disabled "Готово" button
///   that becomes enabled only when every step is done.
///
/// The outer panel uses Apple's native Liquid Glass material
/// (`.liquidGlass(cornerRadius:)`), which automatically refracts the
/// real desktop wallpaper behind the transparent host NSWindow on
/// macOS 26+. We deliberately do NOT paint our own background fill —
/// any solid layer here blocks the glass material from picking up the
/// desktop and produces a "window in window" effect.
///
/// `UnisonUI` cannot import `AppKit`, so anything that must reach into
/// `NSWorkspace` (opening Settings deep links, the OpenAI keys URL) is
/// expressed as an `onOpenURL: (URL) -> Void` callback. The
/// `OnboardingWindowController` in `UnisonApp` provides the actual
/// implementation via `NSWorkspace.shared.open(_:)`.
public struct OnboardingView: View {
    @Bindable var vm: OnboardingViewModel

    /// Caller-provided URL opener (mic settings deep link, OpenAI keys
    /// page). No-op by default — useful in previews and tests.
    let onOpenURL: (URL) -> Void

    /// Optional close handler bound to the title-bar close button, the
    /// `Готово` action, and the ESC key.
    let onClose: () -> Void

    public init(
        vm: OnboardingViewModel,
        onOpenURL: @escaping (URL) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenURL = onOpenURL
        self.onClose = onClose
    }

    public var body: some View {
        panel
            .padding(16)
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
            // ESC closes the window. v1 just closes (per spec).
            .onExitCommand(perform: onClose)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 14) {
            header
            // The cards section can outgrow the 620pt window when one
            // of the steps is in an error state (the `ErrorRow` adds
            // another row underneath the action). The footer is pinned
            // outside the scroll area so progress + "Готово" stay
            // visible regardless of card state.
            ScrollView(.vertical, showsIndicators: false) {
                cards
                    .padding(.bottom, 2)
            }
            .scrollDisabled(false)
            footer
        }
        .padding(20)
        // Outer window: Apple's native Liquid Glass. Inner cards stay
        // flat (content layer) so we don't nest glass-on-glass.
        // The host NSWindow is transparent (no own background) so the
        // glass material refracts the real desktop wallpaper.
        .liquidGlass(cornerRadius: 22)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            logoPlate
            // HIG Materials: vibrant `.primary` for the onboarding
            // title — the system handles contrast against the
            // liquid-glass background.
            Text("Установка")
                .font(.system(size: 22, weight: .light))
                .tracking(-0.66)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
            closeButton
        }
    }

    /// 56×56 rounded-glass plate containing a stroked Unison logo.
    /// Stroke width is scaled to the rendered shape, mirroring the HTML
    /// `stroke-width="12"` inside a `256×256` viewBox.
    private var logoPlate: some View {
        let logoSize: CGFloat = 36
        let strokeWidth = logoSize * 12 / 256
        return ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(UnisonColors.whiteAlpha(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(UnisonColors.whiteAlpha(0.13), lineWidth: 0.5)
                )
                .frame(width: 56, height: 56)
            UnisonLogoShape()
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
                )
                .frame(width: logoSize, height: logoSize)
        }
    }

    private var closeButton: some View {
        IconButton(label: "Закрыть", size: 26, cornerRadius: 7, action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
        }
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 10) {
            blackHoleCard
            microphoneCard
            apiKeyCard
        }
    }

    // MARK: Card · BlackHole

    private var blackHoleCard: some View {
        StepCard(
            title: "BlackHole",
            icon: Image(systemName: "speaker.wave.2.fill"),
            status: cardStatus(for: .blackHole)
        ) {
            cardAction(
                hint: "Нужен пароль системы.",
                primaryTitle: "Установить",
                primaryAction: { Task { await vm.installBlackHole() } },
                isLoading: vm.status[.blackHole]?.isInProgress == true,
                loadingTitle: "Установка…"
            )

            if let message = vm.status[.blackHole]?.errorMessage {
                ErrorRow(
                    title: "Не удалось установить",
                    detail: message,
                    action: .retry(label: "Повторить") {
                        Task { await vm.installBlackHole() }
                    }
                )
                .padding(.top, 12)
            }
        }
    }

    // MARK: Card · Microphone

    private var microphoneCard: some View {
        StepCard(
            title: "Микрофон",
            icon: Image(systemName: "mic.fill"),
            status: cardStatus(for: .microphone)
        ) {
            cardAction(
                hint: "macOS попросит подтверждение.",
                primaryTitle: "Разрешить",
                primaryAction: { Task { await vm.requestMicPermission() } },
                isLoading: vm.status[.microphone]?.isInProgress == true,
                loadingTitle: nil
            )

            if let message = vm.status[.microphone]?.errorMessage {
                ErrorRow(
                    title: "Доступ запрещён",
                    detail: message,
                    action: .openSettings(label: "Открыть Настройки") {
                        if let url = OnboardingViewModel.systemSettingsURL(for: .microphone) {
                            onOpenURL(url)
                        }
                    }
                )
                .padding(.top, 12)
            }
        }
    }

    // MARK: Card · API key

    private var apiKeyCard: some View {
        StepCard(
            title: "OpenAI ключ",
            icon: Image(systemName: "key.fill"),
            status: cardStatus(for: .apiKey)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                DashedDivider()
                    .padding(.top, 0)

                // SecretInput and "Сохранить" stacked vertically. The
                // design HTML puts them side-by-side in a 480pt-wide
                // window, but at our 440pt window the row gets too
                // cramped — the button "ь" was getting clipped against
                // the card edge. Stacking keeps the input full-width and
                // the button right-aligned underneath.
                SecretInput(
                    text: Binding(
                        get: { vm.apiKeyDraft },
                        set: { newValue in
                            vm.apiKeyDraft = newValue
                            // Clear inline validation error while editing.
                            vm.clearError(for: .apiKey)
                        }
                    ),
                    placeholder: "sk-proj-..."
                )
                .padding(.top, 4)

                HStack(spacing: 0) {
                    MutedLink("Получить ключ") {
                        onOpenURL(OnboardingViewModel.openAIKeysURL)
                    }
                    .accessibilityLabel("Получить ключ OpenAI")
                    Spacer(minLength: 8)
                    compactPrimaryButton(
                        title: "Сохранить",
                        action: { vm.saveAPIKey() },
                        isLoading: false,
                        isDisabled: !vm.canSaveKey
                    )
                }

                if let message = vm.status[.apiKey]?.errorMessage {
                    ErrorRow(
                        title: "Неверный ключ",
                        detail: message,
                        action: nil
                    )
                    .padding(.top, 4)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            // HIG Materials: vibrant `.secondary` for the mono
            // progress counter beneath the steps.
            Text(vm.progressLabel)
                .font(UnisonFonts.mono(11))
                .tracking(0.66)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            PrimaryGlassButton(
                title: "Готово",
                action: onClose
            )
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!vm.allDone)
        }
    }

    // MARK: - Helpers

    /// Maps the VM's step status onto the visual card style.
    private func cardStatus(for kind: OnboardingStepKind) -> StepCardStatus {
        switch vm.status[kind] ?? .pending {
        case .pending:    .pending
        case .inProgress: .inProgress
        case .done:       .done
        case .error:      .error
        }
    }

    /// The bottom-of-card row with a hint string on the left and a
    /// primary button on the right (BlackHole + Microphone cards).
    /// Has a dashed top divider matching the design's
    /// `border-top: 0.5px dashed`.
    @ViewBuilder
    private func cardAction(
        hint: String,
        primaryTitle: String,
        primaryAction: @escaping () -> Void,
        isLoading: Bool,
        loadingTitle: String?
    ) -> some View {
        VStack(spacing: 10) {
            DashedDivider()
            HStack(spacing: 10) {
                // HIG Materials: vibrant `.secondary` for inline hint
                // copy next to the primary action button.
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                compactPrimaryButton(
                    title: isLoading ? (loadingTitle ?? primaryTitle) : primaryTitle,
                    action: primaryAction,
                    isLoading: isLoading,
                    isDisabled: false
                )
                .layoutPriority(1)
            }
        }
    }

    /// Small primary button used inside cards. Wraps
    /// `PrimaryGlassButton` so we can constrain its width and disable
    /// the full-width stretch. The button hugs its content (no
    /// `maxWidth: .infinity` stretch) so titles like "Сохранить" /
    /// "Установить" / "Разрешить" render without right-edge clipping
    /// when the row's flexible column (hint text or `SecretInput`) has
    /// already claimed available space.
    @ViewBuilder
    private func compactPrimaryButton(
        title: String,
        action: @escaping () -> Void,
        isLoading: Bool,
        isDisabled: Bool
    ) -> some View {
        PrimaryGlassButton(
            title: title,
            isLoading: isLoading,
            action: action
        )
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isDisabled)
    }
}

// MARK: - Layout constants

private enum OnboardingLayout {
    static let windowWidth: CGFloat = 440
    static let windowHeight: CGFloat = 620
}

