import Foundation
import UnisonDomain
import UnisonTranslation
import UnisonAudio
import UnisonSystem
import UnisonUI

@MainActor
public final class Composition {
    public let registry: CoreAudioDeviceRegistry
    public let orchestrator: TranslationOrchestrator
    public let popoverVM: PopoverViewModel
    public let onboardingVM: OnboardingViewModel
    public let settingsVM: SettingsViewModel
    public let transcriptVM: TranscriptViewModel
    public let permissions: MacPermissions
    public let installer: any BlackHoleInstaller
    public let keychain: MacKeychain
    private let settingsStore = SettingsStore()

    public init() {
        self.registry = CoreAudioDeviceRegistry()
        self.permissions = MacPermissions()
        // UI-test escape hatch: when `UNISON_DEV_MODE=1` is set (or the
        // bundled `.pkg` resources are missing), swap the real
        // BlackHole installer for an in-process mock that succeeds
        // after a short delay. This lets us iterate on the onboarding
        // flow without actually shipping the installer payload.
        self.installer = Self.makeInstaller()
        self.keychain = MacKeychain()

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
    }
}

extension Composition {
    /// Pick a `BlackHoleInstaller`:
    /// - `UNISON_DEV_MODE=1`: always use `MockBlackHoleInstaller`.
    /// - Otherwise: use `BundledBlackHoleInstaller`. If the bundled
    ///   `.pkg` resources are missing we log a warning but still hand
    ///   back the real installer (the user will see the real error
    ///   message if they try to install).
    static func makeInstaller() -> any BlackHoleInstaller {
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
}

/// Development stand-in for `BundledBlackHoleInstaller`. Reports
/// success after a short delay so the UI flow can be exercised end-to-
/// end without root prompts or actual driver installation.
final class MockBlackHoleInstaller: BlackHoleInstaller, @unchecked Sendable {
    private var installed: Bool = false

    func is2chInstalled() -> Bool { installed }
    func is16chInstalled() -> Bool { installed }
    func runBundledInstaller() async throws {
        try await Task.sleep(nanoseconds: 1_500_000_000)
        installed = true
    }
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
