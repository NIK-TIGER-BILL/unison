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
    /// Mark onboarding done AND programmatically show the menubar popover
    /// at launch. Lets the VM screenshot harness capture the popover
    /// surface without AppleScript-clicking the status item (which needs
    /// Accessibility permission and is fragile across notch geometries).
    case popoverOpen = "popover-open"
    /// Mark onboarding done AND auto-invoke `popoverVM.start()` shortly
    /// after launch. Used by `scripts/vm-integration-test.sh` to drive
    /// a full translation cycle without an AppleScript click path —
    /// the harness can SSH into the VM, launch with this state +
    /// `UNISON_TEST_AUDIO=/tmp/speech.wav`, sleep, then pull the
    /// log file back to assert pipeline events fired.
    case startTranslation = "start-translation"
    /// Lifecycle test: auto-start at +2s, auto-stop at +10s, auto-start
    /// again at +14s. Used by the integration suite to prove the
    /// state machine survives a full stop-restart cycle (the most
    /// likely place to find lingering Tasks, audio engine that didn't
    /// release its device, half-closed WS streams, etc.).
    case startStopStart = "start-stop-start"
    /// Seed the meeting archive with synthetic records (in-memory — never
    /// touches the on-disk archive) and open the History window at launch.
    /// Used by the Tart screenshot harness to capture the archive surface.
    case historyDemo = "history-demo"

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
    public let meetingStore: any MeetingStore
    public let meetingHistoryVM: MeetingHistoryViewModel
    public let permissions: any PermissionsService
    public let installer: any BlackHoleInstaller
    public let keychain: any KeychainService

    /// Exposed so `AppDelegate.applicationWillTerminate` can call
    /// `stop()` synchronously and let `BlackHole2chPlayer` patch its
    /// WAV dump header before the process exits. The async
    /// orchestrator.stop() path deadlocks on the main actor when
    /// invoked from applicationWillTerminate (sem.wait blocks main,
    /// the Task hop needs main to run) — so we side-step it for the
    /// audio teardown.
    public let virtualMicPlayer: BlackHole2chPlayer
    public let outputMixer: AVAudioOutputMixer
    private let settingsStore = SettingsStore()

    /// Boot-time diagnostic logger — mirrors to unified logging + the
    /// rotating file logger. Used to surface things that happen during
    /// composition root construction (force-state detection, api-key
    /// source, etc.).
    static let bootLog = UnisonLog(category: "Composition")

    /// Privacy-safe key-shape extractor for diagnostics. Returns only
    /// the *type marker* (e.g. `sk-proj-` for project keys, `sk-` for
    /// legacy) — never any random characters from the secret portion.
    /// The DiagnosticSheet copies recent log lines verbatim, so any
    /// random bytes we log here leak to wherever the user pastes the
    /// diagnostic (chat, email, Slack). Type marker is enough to
    /// distinguish "project key" vs "user key" for triage; full
    /// disambiguation between different keys of the same type isn't
    /// needed once we know the length, source, and prefix shape.
    static func apiKeyPrefix(_ key: String) -> String {
        if key.hasPrefix("sk-proj-") { return "sk-proj-***" }
        if key.hasPrefix("sk-svcacct-") { return "sk-svcacct-***" }
        if key.hasPrefix("sk-admin-") { return "sk-admin-***" }
        if key.hasPrefix("sk-") { return "sk-***" }
        if key.isEmpty { return "<empty>" }
        return "<unknown-shape>"
    }

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

        // `UNISON_API_KEY=sk-...` env override sidesteps the keychain
        // entirely. Used by `scripts/vm-integration-test.sh` because
        // `security add-generic-password` in a Tart VM appears to seed
        // the entry into a partition the app process can't read (the
        // entry IS present — verified — but `SecItemCopyMatching` returns
        // `errSecItemNotFound`). Env passthrough also makes ad-hoc
        // smoke-testing trivial: `UNISON_API_KEY=... open Unison.app`.
        let kc = self.keychain
        let envOverride = ProcessInfo.processInfo.environment["UNISON_API_KEY"]
        let factory = OpenAIRealtimeStreamFactory(
            apiKeyProvider: {
                if let env = envOverride, !env.isEmpty {
                    Self.bootLog.info("apiKey source=env UNISON_API_KEY length=\(env.count) prefix=\(Self.apiKeyPrefix(env))")
                    return env
                }
                let stored = kc.loadAPIKey() ?? ""
                Self.bootLog.info("apiKey source=keychain length=\(stored.count) prefix=\(Self.apiKeyPrefix(stored))")
                return stored
            },
            clock: SystemClock()
        )

        // VM/integration-test seam: `UNISON_TEST_AUDIO=/path/to.wav`
        // substitutes a `FileMicrophoneCapture` for the real engine so
        // the harness can pipe pre-recorded speech through the
        // translation stack without a working input device. Production
        // launches never set this var. See `FileMicrophoneCapture` for
        // the format contract (24 kHz int16 mono, looped).
        let mic: any MicrophoneCapture = {
            if let testAudioPath = ProcessInfo.processInfo.environment["UNISON_TEST_AUDIO"],
               !testAudioPath.isEmpty {
                let expanded = (testAudioPath as NSString).expandingTildeInPath
                FileLogStore.shared.write(
                    category: "Composition",
                    level: "info",
                    message: "UNISON_TEST_AUDIO=\(expanded) — substituting FileMicrophoneCapture for AVAudioEngineMicrophone"
                )
                return FileMicrophoneCapture(fileURL: URL(fileURLWithPath: expanded))
            }
            return AVAudioEngineMicrophone()
        }()
        let settingsStoreRef = settingsStore
        let peerCap = ProcessTapCapture(scopeProvider: {
            let s = settingsStoreRef.load()
            return s.tapScopeMode == .onlySelected
                ? .onlySelected(s.includedTapBundleIDs)
                : .allExcept(s.excludedTapBundleIDs)
        })
        let mixer = AVAudioOutputMixer()
        let bhPlayer = BlackHole2chPlayer(registry: registry)
        self.virtualMicPlayer = bhPlayer
        self.outputMixer = mixer

        self.meetingStore = Self.makeMeetingStore(force: force, settingsStore: settingsStoreRef)
        self.orchestrator = TranslationOrchestrator(
            micCapture: mic,
            peerCapture: peerCap,
            outputMixer: mixer,
            virtualMicPlayer: bhPlayer,
            translationFactory: factory,
            permissions: permissions,
            deviceRegistry: registry,
            clock: SystemClock(),
            transformer: ResamplerAdapter(),
            networkMonitor: NetworkMonitor(),
            meetingStore: self.meetingStore
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
        let orch = self.orchestrator
        self.settingsVM = SettingsViewModel(
            initial: initialSettings,
            deviceRegistry: registry,
            onChange: { s in
                store.save(s)
                popVM.settings = s
                // Live-propagate the settings that can be applied without
                // restarting the session. Without this, dragging the
                // "original mix volume" slider during a Listen-mode
                // session only persists for next start — the running
                // engine keeps the old gain until you stop+restart.
                // Language pair / device UIDs / session mode all
                // require a full restart, so they're applied at the
                // next start() (the popover picker is .disabled while
                // active to make that contract obvious).
                orch.updateOriginalMixVolume(s.originalMixVolume)
                orch.updateSaveHistoryEnabled(s.saveHistoryEnabled)
            },
            keychain: keychain,
            installer: installer,
            hotkeyStore: UserDefaultsHotkeyStorage(),
            togglesStore: UserDefaultsToggleStorage(),
            meetingStore: self.meetingStore
        )
        self.transcriptVM = TranscriptViewModel(
            store: orchestrator.transcript,
            orchestrator: orchestrator
        )
        self.meetingHistoryVM = MeetingHistoryViewModel(store: self.meetingStore)
        // Wire the live-typing-dots pipeline. Without this, the bubble
        // group's `liveEntryId` is always nil → the animated dots that
        // mark "this bubble is still being received" never appear in
        // production, even though the unit tests + design call for it.
        // Weak capture: the VM holds the store strongly, so a strong
        // capture here would create a store ↔ VM retain cycle.
        let transcriptVMRef = self.transcriptVM
        orchestrator.transcript.onDeltaApplied = { [weak transcriptVMRef] entryId in
            transcriptVMRef?.extendLive(entryId: entryId)
        }
        // Project the persisted original-mix volume into the transcript VM
        // so the popover slider opens at the saved value. The VM stores it
        // as an Int 0-100; settings hold a 0.0-1.0 Float.
        self.transcriptVM.originalVolume = Int(
            (initialSettings.originalMixVolume * 100).rounded()
        )
        wireCrossSurfaceSync()

        // Refresh both view-models when CoreAudio reports the hardware
        // roster changed. Without this the input/output pickers stayed
        // frozen on the launch-time snapshot AND the popover's
        // "BlackHole не найден" / "Микрофон не разрешён" blockers
        // wouldn't dismiss after the user installed BlackHole or
        // plugged in a mic. CoreAudio listener fires on `.main`
        // DispatchQueue, so hop to MainActor before touching the
        // @Observable view-models.
        let popVMForRefresh = self.popoverVM
        let settingsVMRef = self.settingsVM
        registry.onDeviceListChanged = { [weak settingsVMRef, weak popVMForRefresh] in
            Task { @MainActor in
                settingsVMRef?.refreshDeviceList()
                settingsVMRef?.refreshBlackHoleStatus()
                popVMForRefresh?.refreshEnvironment()
            }
        }
        // Onboarding completion (mic grant, BlackHole install) doesn't
        // necessarily trigger a CoreAudio device-list event — mic
        // permission grant is a TCC change with no audible event,
        // and a BlackHole install fires the registry listener
        // but with potentially-flaky timing depending on the
        // coreaudiod restart. Bump popover's env tick whenever
        // onboarding's `refresh()` runs so the blocker re-evaluates.
        let popVMForOnboarding = self.popoverVM
        self.onboardingVM.onStateRefreshed = { [weak popVMForOnboarding] in
            popVMForOnboarding?.refreshEnvironment()
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
        meetingStore.enforceSizeLimit()
    }

    /// Cross-surface synchronisation between the three view-models.
    /// Kept out of `init` so the composition root reads as construct →
    /// wire, and each closure documents the bug its absence caused.
    private func wireCrossSurfaceSync() {
        // Persist volume changes back to Settings whenever the user moves
        // the slider in the transcript settings popover. The settings VM
        // exposes the canonical mutation — calling it triggers `onChange`
        // which writes to the SettingsStore.
        let settingsVMRef = self.settingsVM
        self.transcriptVM.onOriginalVolumeChanged = { volume in
            settingsVMRef.setOriginalMixVolume(volume)
        }
        // …and the reverse: moving the Settings-window slider keeps the
        // transcript popover's percentage in sync (display only — the
        // engine gain already flows through `onChange`). Without this,
        // the popover showed a stale value until reopened.
        let transcriptVMForVolume = self.transcriptVM
        self.settingsVM.onOriginalMixVolumeChanged = { [weak transcriptVMForVolume] v in
            transcriptVMForVolume?.originalVolume = Int((v * 100).rounded())
        }
        // Persist popover-side picks (language pair / Call-Listen mode)
        // through the same canonical settings pipeline the window uses.
        // Previously the popover mutated its own in-memory copy: picks
        // were lost on restart and reverted by the next Settings save.
        self.popoverVM.onSettingsChanged = { [weak settingsVMRef] s in
            settingsVMRef?.adoptExternalSettings(s)
        }
        // «Запускать при логине» → SMAppService. The toggle used to be
        // pure UI theater (persisted a bool nobody read).
        self.settingsVM.onAutostartChanged = { enabled in
            LoginItemService.apply(enabled)
        }
    }
}

extension Composition {
    /// Pick a `BlackHoleInstaller`:
    /// - `UNISON_FORCE_STATE=onboarding-done` or `transcript-demo`:
    ///   return a pre-installed mock so the onboarding window stays closed.
    /// - `UNISON_MOCK_BLACKHOLE=1`: explicit opt-in to the mock
    ///   installer (lets QA exercise the in-progress spinner without
    ///   actually running `installer`).
    /// - `UNISON_DEV_MODE=1` **without** a `.app` bundle (i.e.
    ///   `swift run`): use the mock so a fresh contributor doesn't hit
    ///   an actual admin-auth prompt while iterating on UI flows.
    /// - Otherwise: use `BundledBlackHoleInstaller`, which fetches the
    ///   latest BlackHole release from GitHub at runtime.
    static func makeInstaller(force: UnisonForceState? = UnisonForceState.current) -> any BlackHoleInstaller {
        if let force, force == .onboardingDone
            || force == .transcriptDemo
            || force == .popoverOpen
            || force == .startTranslation
            || force == .startStopStart
            || force == .historyDemo {
            print("[Unison] UNISON_FORCE_STATE=\(force.rawValue) — using pre-installed MockBlackHoleInstaller")
            return MockBlackHoleInstaller(preInstalled: true)
        }
        let env = ProcessInfo.processInfo.environment
        // Explicit mock opt-in, independent of `UNISON_DEV_MODE`. Used
        // by snapshot tests / contributors who want the mock spinner
        // even when running the .app.
        if env["UNISON_MOCK_BLACKHOLE"] == "1" {
            print("[Unison] UNISON_MOCK_BLACKHOLE=1 — using MockBlackHoleInstaller")
            return MockBlackHoleInstaller()
        }
        // `swift run` puts the binary somewhere inside `.build/...` —
        // no `.app` wrapper. Use the mock so developers iterating on
        // UI flows don't get hit with a real admin-auth prompt.
        let isAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if env["UNISON_DEV_MODE"] == "1" && !isAppBundle {
            print("[Unison] UNISON_DEV_MODE=1 (no .app bundle) — using MockBlackHoleInstaller")
            return MockBlackHoleInstaller()
        }
        return BundledBlackHoleInstaller()
    }

    /// Pick a `PermissionsService`:
    /// - For the screenshot-harness forcing states we hand back an
    ///   in-memory mock that reports `.granted` for every kind, so
    ///   onboarding's microphone step is already satisfied at boot.
    /// - Otherwise the real `MacPermissions` (prompts the user via
    ///   AVFoundation).
    static func makePermissions(force: UnisonForceState? = UnisonForceState.current) -> any PermissionsService {
        if force == .onboardingDone
            || force == .transcriptDemo
            || force == .popoverOpen
            || force == .startTranslation
            || force == .startStopStart
            || force == .historyDemo {
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
        if force == .onboardingDone || force == .transcriptDemo || force == .popoverOpen
            || force == .historyDemo {
            return InMemoryKeychain(seeded: "sk-unison-vm-screenshot-placeholder-key")
        }
        // Everything else — production launches AND the
        // `startTranslation` / `startStopStart` integration states —
        // uses the real `MacKeychain`: those states run the *real*
        // translation pipeline, so they need a real OpenAI key. The
        // integration script pre-seeds the macOS keychain via
        // `security add-generic-password` before launching, so the
        // production `MacKeychain` resolves correctly; a missing or
        // revoked key keeps the auth-failed path observable.
        return MacKeychain()
    }

    /// Pick the meeting store: an in-memory demo store for the
    /// `history-demo` screenshot harness, else the real file-backed store.
    static func makeMeetingStore(force: UnisonForceState?, settingsStore: SettingsStore) -> any MeetingStore {
        if force == .historyDemo { return makeDemoMeetingStore() }
        return FileMeetingStore.applicationSupport(
            sizeLimitMBProvider: { settingsStore.load().historySizeLimitMB })
    }

    /// In-memory `MeetingStore` seeded with synthetic meetings for the
    /// `UNISON_FORCE_STATE=history-demo` screenshot harness. Custom titles
    /// only (no auto-title) so the captured surface is timezone-independent.
    static func makeDemoMeetingStore() -> InMemoryMeetingStore {
        let store = InMemoryMeetingStore()
        func entry(_ s: Speaker, _ orig: String, _ trans: String, _ at: TimeInterval) -> TranscriptEntry {
            TranscriptEntry(id: UUID(), speaker: s, originalText: orig, translatedText: trans,
                            sourceLanguage: nil, targetLanguage: .ru,
                            timestamp: Date(timeIntervalSince1970: at))
        }
        let base: TimeInterval = 1_718_000_000
        store.save(MeetingRecord(
            id: UUID(), title: "Синк с командой",
            startedAt: Date(timeIntervalSince1970: base),
            endedAt: Date(timeIntervalSince1970: base + 1920),
            mode: .call, languagePair: LanguagePair(mine: .ru, peer: .en),
            entries: [
                entry(.peer, "Let's start with the deployment status — are we on track for Friday?",
                      "Давайте начнём со статуса деплоя — успеваем к пятнице?", base + 60),
                entry(.me, "Бэкенд готов, фронтенд закроем в четверг.",
                      "Backend is done, we'll wrap the frontend on Thursday.", base + 75),
                entry(.peer, "Great. I'll give QA a heads-up to free up a slot.",
                      "Отлично. Я предупрежу QA, чтобы освободили слот.", base + 92)
            ],
            pinned: true))
        store.save(MeetingRecord(
            id: UUID(), title: "Интервью — кандидат",
            startedAt: Date(timeIntervalSince1970: base - 86_400),
            endedAt: Date(timeIntervalSince1970: base - 86_400 + 3060),
            mode: .listen, languagePair: LanguagePair(mine: .ru, peer: .en),
            entries: [
                entry(.peer, "Tell me about a system you designed end to end.",
                      "Расскажите о системе, которую вы спроектировали целиком.", base - 86_400 + 30),
                entry(.peer, "I led the migration to an event-driven pipeline.",
                      "Я вёл миграцию на событийный пайплайн.", base - 86_400 + 70)
            ]))
        store.save(MeetingRecord(
            id: UUID(), title: "Дейли-стендап",
            startedAt: Date(timeIntervalSince1970: base - 3 * 86_400),
            endedAt: Date(timeIntervalSince1970: base - 3 * 86_400 + 900),
            mode: .call, languagePair: LanguagePair(mine: .ru, peer: .en),
            entries: [
                entry(.me, "Вчера закрыл ретеншн, сегодня — ревью PR.",
                      "Yesterday I finished retention, today PR review.", base - 3 * 86_400 + 20)
            ]))
        return store
    }

    /// Seed the transcript store with a handful of bubbles mirroring the
    /// design fixture (`design/transcript-final/index.html` MY_PHRASES /
    /// PEER_PHRASES). Used by `UNISON_FORCE_STATE=transcript-demo`. Note
    /// that the orchestrator's `state` stays `.idle` — the transcript
    /// window can still render historical entries from the store.
    static func seedTranscriptDemo(store: TranscriptStore, viewModel: TranscriptViewModel) {
        store.currentLanguagePair = .default
        let samples: [(speaker: Speaker, original: String, translated: String)] = [
            (.me, "Привет, как дела?", "Hi, how are you?"),
            (.peer, "I'm good, thanks!", "Хорошо, спасибо!"),
            (.me, "Давай встретимся завтра?", "Let's meet tomorrow?"),
            (.peer, "Sounds good to me.", "Звучит хорошо."),
            (.me, "Что насчёт пятницы?", "What about Friday?"),
            (.peer, "Friday works for me. See you then.",
                                                   "Пятница подходит. До встречи.")
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
        // The recency window would trim these 6 seeded replies to the
        // last 4 and empty the transcript 30 s after launch (their
        // timestamps are fixed at seed time, and the screenshot harness
        // captures at an arbitrary post-launch moment). Show the full
        // seeded conversation deterministically instead.
        viewModel.windowingEnabled = false
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
