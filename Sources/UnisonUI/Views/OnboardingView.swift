import SwiftUI

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
            .frame(width: OnboardingLayout.windowWidth, height: OnboardingLayout.windowHeight)
            // No SwiftUI `.liquidGlass()` here anymore. The host
            // `OnboardingWindowController` now wraps content in an
            // `NSVisualEffectView(material: .hudWindow,
            // blendingMode: .behindWindow, state: .active)` — that's
            // the canonical AppKit Liquid Glass surface on macOS
            // Tahoe (same as Notification Center / Spotlight /
            // Control Center). Two glass layers stacked (SwiftUI
            // glassEffect + AppKit NSVisualEffectView) made the
            // surface visually opaque — that was the user's "потерял
            // стиль liquid glass" report. One layer, in AppKit, is
            // both genuinely live AND looks like the right material.
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
        // Inner padding lives BETWEEN the glass surface and the
        // content, not OUTSIDE the glass. This keeps the glass aligned
        // with the NSWindow bounds while preserving content insets.
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
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

    // MARK: Card · BlackHole (Audio setup — two sub-rows)

    private var blackHoleCard: some View {
        StepCard(
            title: "Аудио",
            icon: Image(systemName: "speaker.wave.2.fill"),
            status: cardStatus(for: .blackHole)
        ) {
            VStack(alignment: .leading, spacing: 0) {
                DashedDivider()
                    .padding(.top, 2)

                // Sub-row 1: BlackHole 2ch install
                audioSubRow(
                    label: "Виртуальный микрофон (BlackHole 2ch)",
                    subStatus: vm.blackHoleInstallStatus,
                    buttonTitle: "Установить",
                    loadingTitle: "Установка…",
                    action: { Task { await vm.installBlackHole() } }
                )
                .padding(.top, 10)

                // Escape hatch: manual install link below the install row.
                MutedLink("Установить вручную") {
                    onOpenURL(OnboardingViewModel.blackHoleManualInstallURL)
                }
                .accessibilityLabel("Установить BlackHole вручную")
                .padding(.top, 2)
                .padding(.leading, 22)

                if let message = vm.blackHoleInstallStatus.errorMessage {
                    ErrorRow(
                        title: "Не удалось установить",
                        detail: message,
                        action: .retry(label: "Повторить") {
                            Task { await vm.installBlackHole() }
                        }
                    )
                    .padding(.top, 8)
                }

                DashedDivider()
                    .padding(.top, 12)

                // Sub-row 2: Audio capture (Process Tap TCC grant)
                audioSubRow(
                    label: "Захват системного звука",
                    subStatus: vm.audioCaptureStatus,
                    buttonTitle: "Разрешить",
                    loadingTitle: nil,
                    action: { Task { await vm.requestAudioCapturePermission() } }
                )
                .padding(.top, 10)

                if let message = vm.audioCaptureStatus.errorMessage {
                    ErrorRow(
                        title: "Не удалось получить доступ",
                        detail: message,
                        action: nil
                    )
                    .padding(.top, 8)
                }
            }
        }
    }

    /// A single sub-row inside the Audio card: status icon on the left,
    /// label in the middle, action button on the right. The button is
    /// hidden once the sub-task is done and disabled while it is in
    /// progress. Mirrors the visual weight of the Microphone card's
    /// `cardAction` hint+button row.
    @ViewBuilder
    private func audioSubRow(
        label: String,
        subStatus: OnboardingStepStatus,
        buttonTitle: String,
        loadingTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            subStatusIcon(subStatus)
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if !subStatus.isDone {
                compactPrimaryButton(
                    title: subStatus.isInProgress ? (loadingTitle ?? buttonTitle) : buttonTitle,
                    action: action,
                    isLoading: subStatus.isInProgress,
                    isDisabled: subStatus.isInProgress
                )
                .layoutPriority(1)
            }
        }
    }

    /// Small status icon for an individual sub-task: checkmark when done,
    /// spinner when in progress, empty circle otherwise (and on error).
    @ViewBuilder
    private func subStatusIcon(_ status: OnboardingStepStatus) -> some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UnisonColors.ready)
                .accessibilityLabel("Готово")
        case .inProgress:
            ProgressView()
                .controlSize(.small)
                .frame(width: 14, height: 14)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(UnisonColors.error)
                .accessibilityLabel("Ошибка")
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Ожидание")
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
            // "Готово" is the same minimalist `.glass` button as the
            // per-step actions ("Установить" / "Разрешить" / "Сохранить")
            // — the user asked for a subtler, more native look across
            // the whole onboarding flow.
            compactPrimaryButton(
                title: "Готово",
                action: onClose,
                isLoading: false,
                isDisabled: !vm.allDone
            )
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

    /// Small primary button used inside cards and in the footer. Uses
    /// Apple's native `.buttonStyle(.glass)` for a minimalist,
    /// translucent look — the user explicitly asked for a subtler
    /// affordance than the custom raised `PrimaryGlassButton` and away
    /// from the vivid blue tint of `.glassProminent`. The button hugs
    /// its content via `.fixedSize(horizontal: true)` so loading-state
    /// labels like "Установка…" (which are wider than the resting
    /// "Установить") never overflow the button bounds — the hosting
    /// container stretches naturally to fit the longest string.
    @ViewBuilder
    private func compactPrimaryButton(
        title: String,
        action: @escaping () -> Void,
        isLoading: Bool,
        isDisabled: Bool
    ) -> some View {
        CompactPrimaryButton(
            title: title,
            isLoading: isLoading,
            isDisabled: isDisabled,
            action: action
        )
    }
}

/// Compact primary action button used across `OnboardingView`. Wraps
/// the native `.buttonStyle(.glass)` and carries its own hover state so
/// the cursor's presence is visible — the system glass material on its
/// own animates too subtly against the dark onboarding panel.
///
/// The `title` is whatever copy the caller wants visible (callers swap
/// to a loading-state label like "Установка…" themselves). When
/// `isLoading` is true the button also shows a leading spinner.
private struct CompactPrimaryButton: View {
    let title: String
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    @SwiftUI.State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .buttonStyle(.glass)
        .controlSize(.regular)
        // Natural width — the button hugs the widest label it might
        // ever show. Without `.fixedSize` a long loading-state label
        // ("Установка…") would either truncate or push the row to
        // overflow.
        .fixedSize(horizontal: true, vertical: false)
        .disabled(isDisabled || isLoading)
        // Hover affordance layered on top of the system glass.
        .brightness(isHovered && !isDisabled && !isLoading ? 0.06 : 0)
        .scaleEffect(isHovered && !isDisabled && !isLoading ? 1.02 : 1.0)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.12),
            value: isHovered
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Layout constants

public enum OnboardingLayout {
    public static let windowWidth: CGFloat = 440
    public static let windowHeight: CGFloat = 620
    /// Matches `OnboardingWindowController` so the focus ring (if the
    /// compositor decides to draw one) follows the same rounded
    /// silhouette as the glass card. Public so the AppKit window
    /// controller can wrap NSVisualEffectView at the same radius.
    public static let windowCornerRadius: CGFloat = 22
}
