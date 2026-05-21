import SwiftUI
import UnisonDomain

/// Aurora-glass onboarding window — the first thing the user sees when
/// they launch Unison without all three prerequisites in place.
///
/// Strictly mirrors `design/onboarding-final/index.html`:
/// - Outer Aurora gradient (`auroraBackground()`).
/// - Centred Unison-logo plate (56×56 glass) + "Установка" title.
/// - Three stacked `StepCard`s (BlackHole / Microphone / OpenAI key).
/// - Per-card check badge appears once the step is done; the action
///   button itself swaps to a spinner while a step is in progress.
/// - Coral `ErrorRow` underneath the action when the step fails.
/// - Footer with `X / 3 готово` progress and a disabled "Готово" button
///   that becomes enabled only when every step is done.
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
        ZStack {
            AuroraBackground()
            panel
                .padding(24)
        }
        .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
        // ESC closes the window. v1 just closes (per spec).
        .onExitCommand(perform: onClose)
    }

    // MARK: - Panel

    private var panel: some View {
        VStack(spacing: 18) {
            header
            cards
            footer
        }
        .padding(22)
        .background(panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(UnisonColors.whiteAlpha(0.13), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 28)
    }

    /// Layered background that approximates the design's
    /// `linear-gradient + ::before + ::after` stack: white wash, top
    /// specular highlight. The Aurora itself provides the colour
    /// underneath.
    @ViewBuilder
    private var panelBackground: some View {
        ZStack {
            // 1. Base white-glass wash (top → bottom).
            LinearGradient(
                colors: [
                    UnisonColors.whiteAlpha(0.08),
                    UnisonColors.whiteAlpha(0.02),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 2. Top specular highlight.
            LinearGradient(
                colors: [
                    UnisonColors.whiteAlpha(0.16),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .blendMode(.screen)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            logoPlate
            Text("Установка")
                .font(.system(size: 22, weight: .light))
                .tracking(-0.66)
                .foregroundStyle(UnisonColors.pageFg)
            Spacer(minLength: 0)
            closeButton
        }
    }

    /// 56×56 rounded-glass plate containing a 32px stroked Unison logo.
    private var logoPlate: some View {
        ZStack {
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
                    style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 32, height: 32)
        }
    }

    private var closeButton: some View {
        IconButton(size: 26, cornerRadius: 7, action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
        }
        .accessibilityLabel("Закрыть")
    }

    // MARK: - Cards

    private var cards: some View {
        VStack(spacing: 12) {
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

                HStack(alignment: .center, spacing: 8) {
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

                    compactPrimaryButton(
                        title: "Сохранить",
                        action: { vm.saveAPIKey() },
                        isLoading: false,
                        isDisabled: !vm.canSaveKey
                    )
                }
                .padding(.top, 4)

                MutedLink("Получить ключ") {
                    onOpenURL(OnboardingViewModel.openAIKeysURL)
                }
                .accessibilityLabel("Получить ключ OpenAI")

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
            Text(vm.progressLabel)
                .font(UnisonFonts.mono(11))
                .tracking(0.66)
                .foregroundStyle(UnisonColors.whiteAlpha(0.5))
            Spacer(minLength: 0)
            PrimaryGlassButton(
                title: "Готово",
                action: onClose
            )
            .frame(maxWidth: 120)
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
        VStack(spacing: 12) {
            DashedDivider()
            HStack(spacing: 10) {
                Text(hint)
                    .font(.system(size: 12.5))
                    .foregroundStyle(UnisonColors.whiteAlpha(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                compactPrimaryButton(
                    title: isLoading ? (loadingTitle ?? primaryTitle) : primaryTitle,
                    action: primaryAction,
                    isLoading: isLoading,
                    isDisabled: false
                )
            }
        }
    }

    /// Small primary button used inside cards. Wraps
    /// `PrimaryGlassButton` so we can constrain its width and disable
    /// the full-width stretch.
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
        .frame(maxWidth: 130)
        .disabled(isDisabled)
    }
}

// MARK: - Layout constants

private enum OnboardingLayout {
    static let windowWidth: CGFloat = 440
    static let windowHeight: CGFloat = 620
}

