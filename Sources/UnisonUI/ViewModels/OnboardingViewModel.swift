import Foundation
import Observation
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
    private let permissions: any PermissionsService
    private let installer: any BlackHoleInstaller
    private let keychain: any KeychainService

    public private(set) var steps: [OnboardingStep] = []

    /// Per-step UI state. Always contains an entry for every
    /// `OnboardingStepKind` — `.done` once the underlying check
    /// (`installer`/`permissions`/`keychain`) reports success.
    public private(set) var status: [OnboardingStepKind: OnboardingStepStatus] = [:]

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
        let bhDone = installer.is2chInstalled() && installer.is16chInstalled()
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

    /// Runs the bundled BlackHole installer; reflects progress in
    /// `status[.blackHole]`. On failure the error message is the one
    /// the design specifies under the BlackHole error row.
    ///
    /// The installer is contractually required to verify that BlackHole
    /// devices actually appear in CoreAudio before returning success —
    /// see `BundledBlackHoleInstaller.runBundledInstaller` step 7.
    /// That means on a no-throw return we can trust `is2chInstalled()`
    /// to also be `true`, so we read the status straight from the
    /// installer rather than blindly setting `.done` (which a later
    /// `refresh()` would clobber back to `.pending` if the devices
    /// hadn't actually shown up).
    public func installBlackHole() async {
        status[.blackHole] = .inProgress
        do {
            try await installer.runBundledInstaller()
            // Re-read from the installer (which checks CoreAudio). If
            // it returned without throwing, the post-install
            // verification inside `runBundledInstaller` passed, so this
            // should be `true`. Belt-and-braces guard against a future
            // installer regression.
            if installer.is2chInstalled() && installer.is16chInstalled() {
                status[.blackHole] = .done
            } else {
                status[.blackHole] = .error("Установка завершилась, но BlackHole не появился среди аудиоустройств.")
            }
        } catch let error as BlackHoleInstallError {
            switch error {
            case .verificationFailed:
                status[.blackHole] = .error("BlackHole не появился среди аудиоустройств. Перезапустите Unison или установите вручную.")
            case .installFailed(let detail):
                // `detail` is captured stderr from osascript — usually
                // either "User canceled." or an `installer(8)` error.
                // Most common path is the user dismissing the auth
                // prompt, hence the existing copy.
                let lower = detail.lowercased()
                if lower.contains("canceled") || lower.contains("cancelled") || lower.contains("отмен") {
                    status[.blackHole] = .error("Установка отменена. Введите пароль администратора, чтобы установить BlackHole.")
                } else {
                    status[.blackHole] = .error("Не удалось установить BlackHole. Подробности в Console.app (subsystem com.unison.app).")
                }
            case .downloadFailed:
                status[.blackHole] = .error("Не удалось скачать BlackHole. Проверьте подключение к интернету.")
            case .releaseFetchFailed:
                status[.blackHole] = .error("Не удалось получить информацию о последнем релизе BlackHole с GitHub.")
            case .signatureInvalid:
                status[.blackHole] = .error("Подпись пакета BlackHole не прошла проверку.")
            case .assetsNotFound:
                status[.blackHole] = .error("Не удалось найти пакеты BlackHole для последнего релиза.")
            }
        } catch {
            status[.blackHole] = .error("Не удалось установить BlackHole. Подробности в Console.app (subsystem com.unison.app).")
        }
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
