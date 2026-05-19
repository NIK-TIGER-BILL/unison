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
            }
        )
        self.transcriptVM = TranscriptViewModel(store: orchestrator.transcript)
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
        OpenAIRealtimeStream(apiKey: apiKeyProvider(), client: URLSessionWSClient(), clock: clock)
    }
}
