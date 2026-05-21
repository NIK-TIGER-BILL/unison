import Foundation
import UnisonDomain
import UnisonTranslation
import UnisonAudio
import UnisonSystem
import UnisonUI

/// Snapshot/UI-test forcing flag, parsed once from `UNISON_FORCE_STATE`.
/// Triggers different mocks/seed data at boot so the Tart VM screenshot
/// harness can capture each surface without running the real translation
/// stack. Production builds never set this env var.
public enum UnisonForceState: String, Sendable {
    /// Mark every onboarding step done at boot (used for the "ready" popover screenshot).
    case onboardingDone = "onboarding-done"
    /// Seed `TranscriptStore` with sample bubbles and place the orchestrator
    /// in a translating state so `TranscriptView` renders fully.
    case transcriptDemo = "transcript-demo"
    /// Open the Settings window immediately after launch.
    case settingsOpen = "settings-open"

    /// Resolve from `ProcessInfo.processInfo.environment["UNISON_FORCE_STATE"]`.
    public static var current: UnisonForceState? {
        guard let raw = ProcessInfo.processInfo.environment["UNISON_FORCE_STATE"],
              let parsed = UnisonForceState(rawValue: raw) else { return nil }
        return parsed
    }
}

@MainActor
public final class Composition {
    public let registry: CoreAudioDeviceRegistry
    public let orchestrator: TranslationOrchestrator
    public let popoverVM: PopoverViewModel
    public let onboardingVM: OnboardingViewModel
    public let settingsVM: SettingsViewModel
    public let transcriptVM: TranscriptViewModel
    public let permissions: any PermissionsService
    public let installer: any BlackHoleInstaller
    public let keychain: any KeychainService
    private let settingsStore = SettingsStore()

    public init() {
        self.registry = CoreAudioDeviceRegistry()
        // UI-test escape hatch: when `UNISON_DEV_MODE=1` is set (or the
        // bundled `.pkg` resources are missing), swap the real
        // BlackHole installer for an in-process mock that succeeds
        // after a short delay. This lets us iterate on the onboarding
        // flow without actually shipping the installer payload.
        //
        // `UNISON_FORCE_STATE` (used by the VM screenshot harness)
        // additionally swaps in fully-satisfied permissions/keychain
        // mocks so the onboarding gate is already cleared at launch.
        let force = UnisonForceState.current
        self.permissions = Self.makePermissions(force: force)
        self.installer = Self.makeInstaller(force: force)
        self.keychain = Self.makeKeychain(force: force)

        let kc = self.keychain
        let factory = OpenAIRealtimeStreamFactory(
            apiKeyProvider: { kc.loadAPIKey() ?? "" },
            clock: SystemClock()
        )

        let mic = AVAudioEngineMicrophone()
        let peerCap = BlackHoleSinkCapture(registry: registry)
        let mixer = AVAudioOutputMixer()
        let bhPlayer = BlackHole2chPlayer(registry: registry)

        self.orchestrator = TranslationOrchestrator(
            micCapture: mic,
            peerCapture: peerCap,
            outputMixer: mixer,
            virtualMicPlayer: bhPlayer,
            translationFactory: factory,
            permissions: permissions,
            deviceRegistry: registry,
            clock: SystemClock(),
            transformer: ResamplerAdapter()
        )

        let initialSettings = settingsStore.load()

        self.popoverVM = PopoverViewModel(
            orchestrator: orchestrator,
            permissions: permissions,
            deviceRegistry: registry,
            settings: initialSettings
        )
        self.onboardingVM = OnboardingViewModel(
            permissions: permissions,
            installer: installer,
            keychain: keychain
        )
        let store = settingsStore
        let popVM = self.popoverVM
        self.settingsVM = SettingsViewModel(
            initial: initialSettings,
            deviceRegistry: registry,
            onChange: { s in
                store.save(s)
                popVM.settings = s
            },
            keychain: keychain,
            installer: installer,
            hotkeyStore: UserDefaultsHotkeyStorage(),
            togglesStore: UserDefaultsToggleStorage()
        )
        self.transcriptVM = TranscriptViewModel(
            store: orchestrator.transcript,
            orchestrator: orchestrator
        )
        // Project the persisted original-mix volume into the transcript VM
        // so the popover slider opens at the saved value. The VM stores it
        // as an Int 0-100; settings hold a 0.0-1.0 Float.
        self.transcriptVM.originalVolume = Int(
            (initialSettings.originalMixVolume * 100).rounded()
        )
        // Persist volume changes back to Settings whenever the user moves
        // the slider in the transcript settings popover. The settings VM
        // exposes the canonical mutation — calling it triggers `onChange`
        // which writes to the SettingsStore.
        let settingsVMRef = self.settingsVM
        self.transcriptVM.onOriginalVolumeChanged = { volume in
            settingsVMRef.setOriginalMixVolume(volume)
        }

        // Apply `UNISON_FORCE_STATE` overrides that need to mutate the
        // already-constructed view models / stores. Other overrides
        // (mock installer, granted permissions, pre-seeded keychain)
        // are handled by the factories above.
        if force == .transcriptDemo {
            Self.seedTranscriptDemo(
                store: self.orchestrator.transcript,
                viewModel: self.transcriptVM
            )
        }
    }
}

extension Composition {
    /// Pick a `BlackHoleInstaller`:
    /// - `UNISON_FORCE_STATE=onboarding-done` or `transcript-demo`:
    ///   return a pre-installed mock so the onboarding window stays closed.
    /// - `UNISON_DEV_MODE=1`: use `MockBlackHoleInstaller` that succeeds
    ///   after a short delay (lets QA exercise the in-progress spinner).
    /// - Otherwise: use `BundledBlackHoleInstaller`. If the bundled
    ///   `.pkg` resources are missing we log a warning but still hand
    ///   back the real installer (the user will see the real error
    ///   message if they try to install).
    static func makeInstaller(force: UnisonForceState? = UnisonForceState.current) -> any BlackHoleInstaller {
        if force == .onboardingDone || force == .transcriptDemo {
            print("[Unison] UNISON_FORCE_STATE=\(force!.rawValue) — using pre-installed MockBlackHoleInstaller")
            return MockBlackHoleInstaller(preInstalled: true)
        }
        let env = ProcessInfo.processInfo.environment
        if env["UNISON_DEV_MODE"] == "1" {
            print("[Unison] UNISON_DEV_MODE=1 — using MockBlackHoleInstaller")
            return MockBlackHoleInstaller()
        }
        let real = BundledBlackHoleInstaller()
        // Warn if the bundle doesn't ship the pkgs so a fresh contributor
        // running `swift run Unison` understands why install fails.
        if Bundle.main.url(forResource: "BlackHole2ch", withExtension: "pkg") == nil {
            print("[Unison] warning: BlackHole2ch.pkg not bundled. Run with UNISON_DEV_MODE=1 for a mock installer.")
        }
        return real
    }

    /// Pick a `PermissionsService`:
    /// - For the screenshot-harness forcing states we hand back an
    ///   in-memory mock that reports `.granted` for every kind, so
    ///   onboarding's microphone step is already satisfied at boot.
    /// - Otherwise the real `MacPermissions` (prompts the user via
    ///   AVFoundation).
    static func makePermissions(force: UnisonForceState? = UnisonForceState.current) -> any PermissionsService {
        if force == .onboardingDone || force == .transcriptDemo {
            return ForcedGrantedPermissions()
        }
        return MacPermissions()
    }

    /// Pick a `KeychainService`:
    /// - For the forcing states use an in-memory keychain pre-seeded
    ///   with a placeholder OpenAI key so the onboarding API-key step
    ///   reports `.done`. The placeholder is **not** a real key — it's
    ///   only used to satisfy `validateAPIKey` (`sk-` + 20 chars).
    /// - Otherwise the real `MacKeychain` (writes to the macOS Keychain).
    static func makeKeychain(force: UnisonForceState? = UnisonForceState.current) -> any KeychainService {
        if force == .onboardingDone || force == .transcriptDemo {
            return InMemoryKeychain(seeded: "sk-unison-vm-screenshot-placeholder-key")
        }
        return MacKeychain()
    }

    /// Seed the transcript store with a handful of bubbles mirroring the
    /// design fixture (`design/transcript-final/index.html` MY_PHRASES /
    /// PEER_PHRASES). Used by `UNISON_FORCE_STATE=transcript-demo`. Note
    /// that the orchestrator's `state` stays `.idle` — the transcript
    /// window can still render historical entries from the store.
    static func seedTranscriptDemo(store: TranscriptStore, viewModel: TranscriptViewModel) {
        store.currentLanguagePair = .default
        let samples: [(speaker: Speaker, original: String, translated: String)] = [
            (.me,   "Привет, как дела?",            "Hi, how are you?"),
            (.peer, "I'm good, thanks!",            "Хорошо, спасибо!"),
            (.me,   "Давай встретимся завтра?",     "Let's meet tomorrow?"),
            (.peer, "Sounds good to me.",           "Звучит хорошо."),
            (.me,   "Что насчёт пятницы?",          "What about Friday?"),
            (.peer, "Friday works for me. See you then.",
                                                   "Пятница подходит. До встречи."),
        ]
        for sample in samples {
            let id = UUID()
            // Seed both original + translated in one delta pair so the
            // entry lands with both fields populated.
            store.apply(
                TranscriptDelta(
                    entryId: id,
                    speaker: sample.speaker,
                    kind: .original,
                    text: sample.original,
                    isFinal: true
                )
            )
            store.apply(
                TranscriptDelta(
                    entryId: id,
                    speaker: sample.speaker,
                    kind: .translated,
                    text: sample.translated,
                    isFinal: true
                )
            )
        }
        // Pin the elapsed-time pill at a recognisable value so the
        // screenshot is reproducible across captures.
        viewModel.previewElapsedSeconds = 47
    }
}

/// Development stand-in for `BundledBlackHoleInstaller`. Reports
/// success after a short delay so the UI flow can be exercised end-to-
/// end without root prompts or actual driver installation. The
/// `preInstalled` initializer is used by `UNISON_FORCE_STATE` so the
/// onboarding gate is already cleared for the popover/transcript
/// screenshots.
final class MockBlackHoleInstaller: BlackHoleInstaller, @unchecked Sendable {
    private var installed: Bool

    init(preInstalled: Bool = false) {
        self.installed = preInstalled
    }

    func is2chInstalled() -> Bool { installed }
    func is16chInstalled() -> Bool { installed }
    func runBundledInstaller() async throws {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        installed = true
    }
}

/// `UNISON_FORCE_STATE` helper: report every permission as already
/// granted so `OnboardingViewModel.refresh()` marks the microphone step
/// done at boot. Never used in production.
final class ForcedGrantedPermissions: PermissionsService, @unchecked Sendable {
    func currentStatus(_ kind: PermissionKind) -> PermissionStatus { .granted }
    func request(_ kind: PermissionKind) async -> PermissionStatus { .granted }
    func openSystemSettings(for kind: PermissionKind) {}
}

/// `UNISON_FORCE_STATE` helper: in-memory keychain pre-seeded with a
/// placeholder OpenAI key. The string passes `validateAPIKey` (`sk-`
/// + 20 chars) but is not a real OpenAI credential. Never used in
/// production.
final class InMemoryKeychain: KeychainService, @unchecked Sendable {
    private var key: String?

    init(seeded: String? = nil) {
        self.key = seeded
    }

    func loadAPIKey() -> String? { key }
    func saveAPIKey(_ value: String) throws { key = value }
    func deleteAPIKey() throws { key = nil }
}

final class SettingsStore: @unchecked Sendable {
    private let key = "com.unison.settings.v1"
    func load() -> Settings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            return .default
        }
        return s
    }
    func save(_ s: Settings) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

final class OpenAIRealtimeStreamFactory: TranslationStreamFactory, @unchecked Sendable {
    private let apiKeyProvider: () -> String
    private let clock: any Clock

    init(apiKeyProvider: @escaping () -> String, clock: any Clock) {
        self.apiKeyProvider = apiKeyProvider
        self.clock = clock
    }

    func make(speaker: Speaker) -> any TranslationStream {
        OpenAIRealtimeStream(apiKey: apiKeyProvider(), client: URLSessionWSClient(), clock: clock, speaker: speaker)
    }
}

/// UserDefaults-backed persistence for the two hotkeys configured in
/// Settings. Stored as JSON so the encoding stays stable across version
/// bumps to `Hotkey` (the value type is Codable).
final class UserDefaultsHotkeyStorage: HotkeyStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "com.unison.hotkey.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for kind: HotkeyKind) -> String { prefix + kind.rawValue }

    func loadHotkey(_ kind: HotkeyKind) -> Hotkey? {
        guard let data = defaults.data(forKey: key(for: kind)) else { return nil }
        return try? JSONDecoder().decode(Hotkey.self, from: data)
    }

    func saveHotkey(_ kind: HotkeyKind, _ hotkey: Hotkey?) {
        let k = key(for: kind)
        guard let hotkey else {
            defaults.removeObject(forKey: k)
            return
        }
        if let data = try? JSONEncoder().encode(hotkey) {
            defaults.set(data, forKey: k)
        }
    }
}

/// UserDefaults-backed persistence for the behaviour toggles.
final class UserDefaultsToggleStorage: ToggleStorage, @unchecked Sendable {
    private let defaults: UserDefaults
    private let prefix = "com.unison.toggle.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(for kind: BehaviorToggle) -> String { prefix + kind.rawValue }

    func loadToggle(_ kind: BehaviorToggle, default fallback: Bool) -> Bool {
        let k = key(for: kind)
        if defaults.object(forKey: k) == nil { return fallback }
        return defaults.bool(forKey: k)
    }

    func saveToggle(_ kind: BehaviorToggle, _ value: Bool) {
        defaults.set(value, forKey: key(for: kind))
    }
}
