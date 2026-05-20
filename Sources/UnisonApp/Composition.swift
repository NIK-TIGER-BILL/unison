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
    public let installer: BundledBlackHoleInstaller
    public let keychain: MacKeychain
    private let settingsStore = SettingsStore()

    public init() {
        self.registry = CoreAudioDeviceRegistry()
        self.permissions = MacPermissions()
        self.installer = BundledBlackHoleInstaller()
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
