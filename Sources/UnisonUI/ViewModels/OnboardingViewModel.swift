import AppKit
import Foundation
import Observation
import UnisonAudio
import UnisonDomain

public enum OnboardingStepKind: Sendable, Hashable {
    case blackHole
    case microphone
    case apiKey
}

/// Per-step UI state. Mirrors the design HTML's `card`/`error`/`done`
/// classes. The `inProgress` case carries no payload — the spinner is a
/// purely visual concern. `error` carries a Russian message ready for
/// display in an `ErrorRow`.
public enum OnboardingStepStatus: Equatable, Sendable {
    case pending
    case inProgress
    case done
    case error(String)

    public var isDone: Bool {
        if case .done = self { return true } else { return false }
    }

    public var isInProgress: Bool {
        if case .inProgress = self { return true } else { return false }
    }

    public var errorMessage: String? {
        if case .error(let message) = self { return message } else { return nil }
    }
}

public struct OnboardingStep: Identifiable, Sendable {
    public let id = UUID()
    public let kind: OnboardingStepKind
    public let isDone: Bool
}

/// Drives the onboarding window: tracks which prerequisites are still
/// pending (BlackHole install / mic permission / OpenAI key) and exposes
/// per-step status for the new Aurora card design (`OnboardingView`).
///
/// The VM stays UI-framework-free. The view observes `status[kind]` to
/// show spinners, error rows, and the done check.
@MainActor
@Observable
public final class OnboardingViewModel {
    static let log = UnisonLog(category: "OnboardingViewModel")

    private let permissions: any PermissionsService
    private let installer: any BlackHoleInstaller
    private let keychain: any KeychainService

    public private(set) var steps: [OnboardingStep] = []

    /// Per-step UI state. Always contains an entry for every
    /// `OnboardingStepKind` — `.done` once the underlying check
    /// (`installer`/`permissions`/`keychain`) reports success.
    public private(set) var status: [OnboardingStepKind: OnboardingStepStatus] = [:]

    /// Sub-state for the "Allow audio capture" sub-task inside the
    /// `.blackHole` (Audio setup) step. Tracked separately from
    /// `status[.blackHole]` because the overall step requires BOTH the
    /// BlackHole 2ch install AND audio capture grant.
    public private(set) var audioCaptureStatus: OnboardingStepStatus = .pending

    /// Sub-state for the BlackHole 2ch install sub-task. Same rationale.
    public private(set) var blackHoleInstallStatus: OnboardingStepStatus = .pending

    /// Mutable draft for the OpenAI key input. The view binds directly.
    /// Cleared on successful save.
    public var apiKeyDraft: String = ""

    /// Optional callback fired when `allDone` flips to `true`. The
    /// window controller wires this to close the window. Setting the
    /// callback after `allDone` is already true will fire it
    /// immediately. Subsequent identical-state `refresh()` calls do
    /// not re-fire.
    @ObservationIgnored
    public var onCompleted: (() -> Void)? {
        didSet {
            if allDone, !completionFired {
                completionFired = true
                onCompleted?()
            }
        }
    }

    /// Guards `onCompleted` from firing repeatedly when `refresh()` is
    /// called after the final step transitions to `.done`.
    private var completionFired = false

    /// Fires on every `refresh()` (mic grant probed, BlackHole install
    /// finished, key saved). Composition wires this to bump
    /// `PopoverViewModel.refreshEnvironment()` so the popover's
    /// "blocked" banner re-evaluates without waiting for a CoreAudio
    /// device-list event (which doesn't fire for TCC grants and can
    /// race with coreaudiod restart for BH installs).
    @ObservationIgnored
    public var onStateRefreshed: (@MainActor () -> Void)?

    public init(
        permissions: any PermissionsService,
        installer: any BlackHoleInstaller,
        keychain: any KeychainService
    ) {
        self.permissions = permissions
        self.installer = installer
        self.keychain = keychain
        refresh()
    }

    public func refresh() {
        let bh2chDone = installer.is2chInstalled()
        // Audio capture grant is not queryable via public API. We only know
        // the user clicked through onboarding by reading our own state.
        let audioCaptureDone = audioCaptureStatus.isDone
        let bhDone = bh2chDone && audioCaptureDone

        // Reflect install state in the sub-state property (preserves in-progress / error).
        if bh2chDone {
            blackHoleInstallStatus = .done
        } else if case .inProgress = blackHoleInstallStatus {
            // leave it
        } else if case .error = blackHoleInstallStatus {
            // preserve error
        } else {
            blackHoleInstallStatus = .pending
        }

        let micDone = permissions.currentStatus(.microphone) == .granted
        let keyDone = keychain.loadAPIKey()?.isEmpty == false
        steps = [
            OnboardingStep(kind: .blackHole, isDone: bhDone),
            OnboardingStep(kind: .microphone, isDone: micDone),
            OnboardingStep(kind: .apiKey, isDone: keyDone)
        ]

        // Carry over `.inProgress` (an in-flight task) but otherwise
        // resolve to `.done` or `.pending`. Existing `.error` entries
        // are kept so the user can see them until they retry.
        for step in steps {
            let previous = status[step.kind]
            if step.isDone {
                status[step.kind] = .done
            } else if case .inProgress = previous {
                // Leave it; the awaiting task will overwrite on completion.
            } else if case .error = previous {
                // Preserve the error message until the user retries.
            } else {
                status[step.kind] = .pending
            }
        }

        // Keep overall .blackHole in sync with the two sub-states.
        refreshOverallBlackHoleStatus()

        // Fire the completion callback exactly once. We only mark
        // `completionFired` when the callback actually ran, so that a
        // controller wiring `onCompleted` *after* construction still
        // gets a single deferred notification.
        if !completionFired, allDone, let onCompleted {
            completionFired = true
            onCompleted()
        }
        onStateRefreshed?()
    }

    public var allDone: Bool { steps.allSatisfy(\.isDone) }

    /// Convenience: `2 / 3 готово` style label for the footer.
    public var progressLabel: String {
        let done = steps.filter(\.isDone).count
        let total = steps.count
        return "\(done) / \(total) готово"
    }

    /// Pure key validator — exposed `nonisolated` so tests can call
    /// without an actor hop. Matches the HTML reference
    /// (`startsWith('sk-') && length >= 20`).
    public nonisolated static func validateAPIKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-") && trimmed.count >= 20
    }

    /// Instance helper that validates the current draft.
    public func validateAPIKey() -> Bool {
        Self.validateAPIKey(apiKeyDraft)
    }

    /// Save-button gate: the Save button is enabled only when the draft
    /// passes validation. The draft must be non-empty and start with
    /// `sk-`.
    public var canSaveKey: Bool {
        validateAPIKey()
    }

    // MARK: - Step actions

    /// Runs the bundled BlackHole 2ch installer; reflects progress in
    /// `blackHoleInstallStatus`. The overall `status[.blackHole]` is the
    /// AND of `blackHoleInstallStatus` and `audioCaptureStatus`.
    public func installBlackHole() async {
        blackHoleInstallStatus = .inProgress
        refreshOverallBlackHoleStatus()
        do {
            try await installer.runBundledInstaller()
            if installer.is2chInstalled() {
                blackHoleInstallStatus = .done
            } else {
                blackHoleInstallStatus = .error(
                    "Установка завершилась, но BlackHole 2ch не появился среди аудиоустройств."
                )
            }
        } catch let error as BlackHoleInstallError {
            switch error {
            case .verificationFailed:
                blackHoleInstallStatus = .error(
                    "BlackHole 2ch не появился среди аудиоустройств. Перезапустите Unison или установите вручную."
                )
            case .installFailed(let detail):
                let lower = detail.lowercased()
                if lower.contains("canceled") || lower.contains("cancelled") || lower.contains("отмен") {
                    blackHoleInstallStatus = .error(
                        "Установка отменена. Введите пароль администратора, чтобы установить BlackHole 2ch."
                    )
                } else {
                    blackHoleInstallStatus = .error(
                        "Не удалось установить BlackHole. Подробности в Console.app (subsystem com.unison.app)."
                    )
                }
            case .downloadFailed:
                blackHoleInstallStatus = .error(
                    "Не удалось скачать BlackHole. Проверьте подключение к интернету."
                )
            case .releaseFetchFailed:
                blackHoleInstallStatus = .error(
                    "Не удалось получить информацию о последнем релизе BlackHole с GitHub."
                )
            case .signatureInvalid:
                blackHoleInstallStatus = .error(
                    "Подпись пакета BlackHole не прошла проверку."
                )
            case .assetsNotFound:
                blackHoleInstallStatus = .error(
                    "Не удалось найти пакет BlackHole 2ch для последнего релиза."
                )
            }
        } catch {
            blackHoleInstallStatus = .error(
                "Не удалось установить BlackHole. Подробности в Console.app (subsystem com.unison.app)."
            )
        }
        refresh()
    }

    /// Recomputes overall `status[.blackHole]` from the two sub-states.
    private func refreshOverallBlackHoleStatus() {
        let install = blackHoleInstallStatus
        let capture = audioCaptureStatus
        if install.isDone && capture.isDone {
            status[.blackHole] = .done
        } else if case .error(let m) = install {
            status[.blackHole] = .error(m)
        } else if case .error(let m) = capture {
            status[.blackHole] = .error(m)
        } else if install.isInProgress || capture.isInProgress {
            status[.blackHole] = .inProgress
        } else {
            status[.blackHole] = .pending
        }
    }

    /// Triggers the macOS TCC audio-capture prompt by creating + immediately
    /// destroying a throwaway Process Tap. macOS does not expose a public API
    /// to query the resulting permission state, so this method optimistically
    /// marks the sub-task as `.done` once the prompt has been dismissed. The
    /// actual "translation gets silent buffers" case is caught at runtime by
    /// the silent-frame watchdog and surfaces a banner with a System Settings
    /// deep link.
    public func requestAudioCapturePermission() async {
        Self.log.info("requestAudioCapturePermission() called")
        audioCaptureStatus = .inProgress
        refreshOverallBlackHoleStatus()
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        AudioCapturePermission.triggerPrompt()
        Self.log.info("AudioCapturePermission.triggerPrompt() returned")
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        audioCaptureStatus = .done
        refresh()
    }

    /// Asks AVFoundation for microphone permission. If the user denies
    /// (or has previously denied) we surface the "open System Settings"
    /// error per design.
    public func requestMicPermission() async {
        status[.microphone] = .inProgress
        let result = await permissions.request(.microphone)
        switch result {
        case .granted:
            status[.microphone] = .done
        case .denied:
            status[.microphone] = .error("Доступ запрещён. Включите микрофон для Unison в Настройках системы.")
        case .notDetermined:
            status[.microphone] = .pending
        }
        refresh()
    }

    /// Validates and persists the OpenAI key from the draft. On invalid
    /// input the card flips to the error state with the validation
    /// message from the design (sk- prefix + 20 chars). On Keychain
    /// failure we use a generic message.
    public func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validateAPIKey(trimmed) else {
            status[.apiKey] = .error("Ключ должен начинаться с sk- и быть длиннее 20 символов.")
            return
        }
        do {
            try keychain.saveAPIKey(trimmed)
            apiKeyDraft = ""
            status[.apiKey] = .done
            refresh()
        } catch {
            status[.apiKey] = .error("Не удалось сохранить ключ в Keychain.")
        }
    }

    /// Backward-compatible overload accepting a raw string. Persists
    /// the key without the strict validator (so existing tests using
    /// short fixtures keep passing). Validated saves go through
    /// `saveAPIKey()` and `apiKeyDraft`.
    public func saveAPIKey(_ key: String) throws {
        try keychain.saveAPIKey(key)
        refresh()
    }

    /// Clears any error for the given step. Used when the user edits
    /// the key field — the design clears the error on input.
    public func clearError(for kind: OnboardingStepKind) {
        if case .error = status[kind] {
            status[kind] = .pending
        }
    }

    /// Snapshot-only helper to force a step into a specific UI state.
    /// Production code drives `status` through the install/permission/
    /// keychain flows; previews use this to render the spinner / error
    /// rows without actually running async work.
    public func setStatus(_ value: OnboardingStepStatus, for kind: OnboardingStepKind) {
        status[kind] = value
    }

    /// Returns the deep-link URL to the relevant System Settings pane
    /// for the given step. Currently only the microphone error has a
    /// deep link. Returns `nil` for steps without an associated URL.
    public nonisolated static func systemSettingsURL(for kind: OnboardingStepKind) -> URL? {
        switch kind {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        case .blackHole, .apiKey:
            return nil
        }
    }

    /// External URL for the OpenAI API-keys page (shown as
    /// `Получить ключ ↗` under the secret input).
    public nonisolated static var openAIKeysURL: URL {
        URL(string: "https://platform.openai.com/api-keys")!
    }

    /// External URL for the BlackHole manual install page. Surfaced as
    /// a muted `Установить вручную ↗` link in the BlackHole onboarding
    /// card so the user has an escape hatch if the automated install
    /// flow fails for any reason (permission denied, network outage,
    /// CoreAudio quirk, etc).
    public nonisolated static var blackHoleManualInstallURL: URL {
        URL(string: "https://existential.audio/blackhole/")!
    }
}
