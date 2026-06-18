import Foundation
import Observation
import UnisonDomain

public enum StartBlockedReason: Equatable, Sendable {
    case micPermissionRequired
    case blackHole2chMissing
}

/// Tiny enum for the popover's primary button icon. Mapped at the view
/// layer to an SF Symbol (`play.fill` / `stop.fill`).
public enum PopoverPrimaryIcon: Sendable {
    case play
    case stop
}

@MainActor
@Observable
public final class PopoverViewModel {
    /// Diagnostic logger for the popover view-model. Mirrors to both
    /// unified logging and `~/Library/Logs/Unison/unison.log` — see
    /// `UnisonLog`. Lets you see exactly which step of `start()` is
    /// reached (or skipped) when a click on "Начать перевод" appears
    /// to do nothing.
    @ObservationIgnored
    static let log = UnisonLog(category: "PopoverVM")

    private let orchestrator: TranslationOrchestrator?
    private let permissions: any PermissionsService
    private let deviceRegistry: any AudioDeviceRegistry
    public var settings: Settings

    /// Fired by the popover's own mutators (`updateLanguagePair`,
    /// `updateSessionMode`) so the host can persist the change through
    /// the canonical settings pipeline. Without it the popover mutated
    /// a local copy only: picks were lost on restart and silently
    /// reverted by the next Settings-window save.
    @ObservationIgnored
    public var onSettingsChanged: ((Settings) -> Void)?

    /// Test-only override for the session state. When the VM is
    /// constructed via `previewing(...)` the state is sourced from this
    /// property instead of an orchestrator. Production code never
    /// touches this — `orchestrator.state` always wins when it exists.
    public var previewState: SessionState = .idle

    /// Test-only override for the aggregate `ConnectivityHealth`. Read
    /// by `connectivityHealth` only when no orchestrator is wired (i.e.
    /// the VM was built via `previewing(...)`). `internal` (not
    /// `private`) so snapshot tests reaching in via
    /// `@testable import UnisonUI` can prime a state without driving the
    /// real orchestrator.
    var previewConnectivityHealth: ConnectivityHealth = .healthy

    /// Monotonic tick bumped whenever the *environment* changes —
    /// device list, BlackHole install, mic permission grant. The
    /// `startBlockedReason` computation reads it (via `_ = envTick`)
    /// so SwiftUI's Observation invalidates the popover the moment
    /// CoreAudio reports new hardware. Without this, plugging in a
    /// new mic / installing BlackHole through onboarding wouldn't
    /// dismiss the "BlackHole не найден" / "Микрофон не разрешён"
    /// blocker until the user clicked Start (which would succeed
    /// because the orchestrator re-reads on its own — misleading
    /// state in the meantime).
    public private(set) var envTick: Int = 0

    /// Public so Composition can ping it from the registry's
    /// `onDeviceListChanged` hook. Marked `@MainActor` because the
    /// VM is.
    public func refreshEnvironment() {
        envTick &+= 1
    }

    public init(
        orchestrator: TranslationOrchestrator,
        permissions: any PermissionsService,
        deviceRegistry: any AudioDeviceRegistry,
        settings: Settings
    ) {
        self.orchestrator = orchestrator
        self.permissions = permissions
        self.deviceRegistry = deviceRegistry
        self.settings = settings
    }

    /// Private init used by `previewing(...)` for snapshot tests — no
    /// orchestrator, state driven by `previewState`. Marked
    /// `nonisolated(unsafe)` is unnecessary because the factory hops
    /// onto the MainActor anyway.
    private init(
        permissions: any PermissionsService,
        deviceRegistry: any AudioDeviceRegistry,
        settings: Settings,
        previewState: SessionState
    ) {
        self.orchestrator = nil
        self.permissions = permissions
        self.deviceRegistry = deviceRegistry
        self.settings = settings
        self.previewState = previewState
    }

    /// Factory for snapshot/preview use. Skips the orchestrator entirely
    /// so the VM can be constructed without spinning up the full audio
    /// stack. Mirrors what `Composition.swift` builds in production but
    /// substitutes the `state` source for an immutable override.
    public static func previewing(
        settings: Settings = .default,
        state: SessionState = .idle,
        permissions: any PermissionsService,
        deviceRegistry: any AudioDeviceRegistry,
        connectivityHealth: ConnectivityHealth = .healthy
    ) -> PopoverViewModel {
        let vm = PopoverViewModel(
            permissions: permissions,
            deviceRegistry: deviceRegistry,
            settings: settings,
            previewState: state
        )
        vm.previewConnectivityHealth = connectivityHealth
        return vm
    }

    public var state: SessionState { orchestrator?.state ?? previewState }

    /// Aggregate connectivity health, read from the orchestrator when
    /// available, falls back to the preview override otherwise. The UI
    /// only surfaces this when `state == .translating` (the other states
    /// already speak for themselves); the view-model still keeps the
    /// fallback so the property is well-defined in every state.
    public var connectivityHealth: ConnectivityHealth {
        orchestrator?.connectivityHealth ?? previewConnectivityHealth
    }

    public var runningTimeSeconds: TimeInterval {
        // Read through `sessionStartedAt` so the timer keeps ticking
        // during `.reconnecting` instead of snapping back to 00:00 every
        // time a flapping stream forces a reconnect. The session start is
        // preserved by the orchestrator across reconnect attempts.
        if let startedAt = state.sessionStartedAt {
            return Date().timeIntervalSince(startedAt)
        }
        return 0
    }

    /// `mm:ss` formatted version of `runningTimeSeconds`.
    /// Returns `"00:00"` when no session is running.
    public var elapsedSecondsString: String {
        Self.formatElapsed(runningTimeSeconds)
    }

    /// Pure formatter — exposed `nonisolated` so tests can call without an
    /// actor hop.
    public nonisolated static func formatElapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let mm = s / 60
        let ss = s % 60
        return String(format: "%02d:%02d", mm, ss)
    }

    public var canStart: Bool { startBlockedReason == nil }

    /// `true` when the two languages differ. Same-language is the only
    /// content-level validation the popover surfaces; everything else
    /// (permissions, BlackHole) is folded into `startBlockedReason`.
    public var isLanguagePairValid: Bool {
        settings.languagePair.mine != settings.languagePair.peer
    }

    /// Strict gate for the Start button — combines the environment check
    /// (`canStart`) with content validation (`isLanguagePairValid`).
    public var canStartStrict: Bool { canStart && isLanguagePairValid }

    /// Human-readable status line shown below the timer / primary
    /// button. Empty string means "no secondary line at all" — the row
    /// collapses entirely in that case so we don't reserve vertical
    /// space for an unused hint.
    ///
    /// Exhaustively covers every `SessionState`; `.translating`
    /// additionally branches on `connectivityHealth` for the slow /
    /// recovery surface.
    public var statusText: String {
        switch state {
        case .idle, .connecting, .error:
            return ""
        case .reconnecting:
            return "Переподключение…"
        case .paused(_, _, _, .networkLost):
            return "Нет интернета. Ждём…"
        case .paused(_, _, _, .awaitingNetwork):
            return "Возобновляем…"
        case .translating:
            switch connectivityHealth {
            case .slow: return "Медленная сеть"
            case .recovering: return "Связь восстановлена"
            case .healthy: return ""
            }
        }
    }

    /// The popover header status dot, derived from
    /// `state × connectivityHealth`. This is the single source of truth
    /// for the header dot — `PopoverView` binds straight to it. The
    /// colour mapping mirrors the design spec's status table
    /// (`docs/superpowers/specs/2026-05-27-network-aware-session-design.md`,
    /// "Status dot colour" column) exactly:
    ///
    /// | state / health                  | dot          |
    /// | ------------------------------- | ------------ |
    /// | `.idle` (valid pair)            | `.ready`     |
    /// | `.idle` (invalid pair)          | `.warn`      |
    /// | `.connecting`                   | `.active`    |
    /// | `.translating` + `.healthy`     | `.active`    |
    /// | `.translating` + `.slow`        | `.warn`      |
    /// | `.translating` + `.recovering`  | `.recovering`|
    /// | `.paused(.networkLost)`         | `.paused`    |
    /// | `.paused(.awaitingNetwork)`     | `.active`    |
    /// | `.reconnecting`                 | `.warn`      |
    /// | `.error`                        | `.error`     |
    ///
    /// Note `.error` maps to `.error` (red) and `.paused(.awaitingNetwork)`
    /// to `.active` (cyan, "returning") — getting either wrong was the
    /// gap the final PR review caught (the header previously routed
    /// through a 4-state projection that collapsed paused / slow /
    /// recovering all to cyan).
    public var statusDotState: StatusDot.State {
        switch state {
        case .idle:
            return isLanguagePairValid ? .ready : .warn
        case .connecting:
            return .active
        case .reconnecting:
            return .warn
        case .paused(_, _, _, .networkLost):
            return .paused
        case .paused(_, _, _, .awaitingNetwork):
            return .active
        case .error:
            return .error
        case .translating:
            switch connectivityHealth {
            case .slow: return .warn
            case .recovering: return .recovering
            case .healthy: return .active
            }
        }
    }

    /// Title for the primary action button.
    public var primaryButtonTitle: String {
        state.isActive ? "Остановить" : "Начать перевод"
    }

    /// Icon for the primary action button.
    public var primaryButtonIcon: PopoverPrimaryIcon {
        state.isActive ? .stop : .play
    }

    public var startBlockedReason: StartBlockedReason? {
        // Touch `envTick` so SwiftUI's Observation tracks it. Without
        // this, none of the dependencies below (permissions / registry)
        // are Observable, so the popover never refreshes when the user
        // grants mic permission or installs BlackHole from onboarding.
        _ = envTick
        let mode = settings.sessionMode
        // Mic permission required by any mode that captures mic.
        if mode.requiresMicrophone,
           permissions.currentStatus(.microphone) == .denied {
            return .micPermissionRequired
        }
        // BlackHole 2ch only required by `.call` (virtual mic for peer).
        if mode == .call, deviceRegistry.findBlackHole2ch() == nil {
            return .blackHole2chMissing
        }
        return nil
    }

    public func start() async {
        // Snapshot the pre-flight environment so silent failures stop
        // being silent. Every line here lands in unified logging under
        // `com.unison.app`/`PopoverVM`.
        let mode = settings.sessionMode
        let mineCode = settings.languagePair.mine.rawValue
        let peerCode = settings.languagePair.peer.rawValue
        let blocked = String(describing: startBlockedReason)
        let micStatus = String(describing: permissions.currentStatus(.microphone))
        let bh2 = deviceRegistry.findBlackHole2ch() != nil
        let preState = String(describing: state)
        Self.log.info("start() called — mode=\(mode.rawValue), pair=\(mineCode)→\(peerCode)")
        Self.log.info("start() pre-flight — blockedReason=\(blocked), mic=\(micStatus), BH2ch=\(bh2 ? "present" : "missing"), state=\(preState)")

        if orchestrator == nil {
            Self.log.error("start() — orchestrator is nil (preview VM); skipping")
            return
        }

        // If the previous attempt parked us in `.error` (e.g. transient
        // network blip surfaced before reconnect succeeded, or the user
        // pulled BlackHole mid-session), the orchestrator's
        // `guard case .idle = state` rejects a fresh start() and the
        // user-facing "Начать перевод" button appears dead. Reset to
        // idle here so the click does what it says.
        if case .error = state {
            Self.log.info("start() — resetting from .error to .idle before fresh attempt")
            await orchestrator?.stop()
        }

        await orchestrator?.start(mode: mode, languages: settings.languagePair, settings: settings)
        let postState = String(describing: state)
        Self.log.info("start() returned — state=\(postState)")
    }

    /// Self-test entry point. Overrides the user-visible Call/Listen
    /// pick and runs a `.test` session (mic → translate → speakers,
    /// transcript shown, no BlackHole). The user's saved
    /// `settings.sessionMode` is NOT touched — once they stop the
    /// test session, the Start button still reflects whichever mode
    /// (Call or Listen) they had selected. Bound to the waveform
    /// icon in the popover header.
    public func startTest() async {
        Self.log.info("startTest() called — state=\(String(describing: self.state))")
        if orchestrator == nil {
            Self.log.error("startTest() — orchestrator is nil (preview VM); skipping")
            return
        }
        // Same .error → .idle reset as the regular start() — without
        // this a click on Проверка right after a failed session
        // appears dead.
        if case .error = state {
            Self.log.info("startTest() — resetting from .error to .idle before fresh attempt")
            await orchestrator?.stop()
        }
        await orchestrator?.start(mode: .test, languages: settings.languagePair, settings: settings)
        Self.log.info("startTest() returned — state=\(String(describing: state))")
    }

    public func stop() async {
        Self.log.info("stop() called — state=\(String(describing: self.state))")
        await orchestrator?.stop()
        Self.log.info("stop() returned — state=\(String(describing: self.state))")
    }

    /// Switch between Call and Listen. Persists via `onSettingsChanged`.
    public func updateSessionMode(_ mode: SessionMode) {
        guard settings.sessionMode != mode else { return }
        settings.sessionMode = mode
        onSettingsChanged?(settings)
    }

    /// Replace the current language pair. Centralising the write keeps
    /// the view layer from poking at `settings.languagePair` directly,
    /// and routes the change into the persistent settings pipeline.
    public func updateLanguagePair(_ pair: LanguagePair) {
        settings.languagePair = pair
        onSettingsChanged?(settings)
    }

    /// Russian user-facing message for a `TranslationError` surfaced via
    /// the popover. Kept on the view-model so tests can verify the
    /// mapping without instantiating SwiftUI views. Wording stays short
    /// per the project's UX-copy convention (see MEMORY.md).
    public nonisolated static func userMessage(for error: TranslationError) -> String {
        switch error {
        case .permissionDenied(.microphone):
            return "Нет доступа к микрофону. Откройте Настройки → Privacy & Security → Microphone."
        case .blackHole2chMissing:
            return "BlackHole 2ch не найден. Установите драйвер в Onboarding."
        case .networkLost:
            return "Нет связи с серверами OpenAI. Проверьте интернет."
        case .apiKeyInvalid:
            // Markdown link — ErrorRow renders the message through a
            // `Text(LocalizedStringKey(...))` initializer that auto-
            // parses `[label](url)` into a clickable link, while the
            // surrounding text stays selectable via `.textSelection`.
            return "OpenAI ключ невалидный. Проверьте на [platform.openai.com/api-keys](https://platform.openai.com/api-keys) или вставьте новый в Настройках."
        case .rateLimited:
            return "Превышен лимит запросов OpenAI. Повторите позже."
        case .insufficientCredits:
            return "Закончились средства OpenAI. Пополните баланс."
        case .inputDeviceUnavailable:
            return "Микрофон недоступен. Выберите другое устройство в Настройках."
        case .outputDeviceUnavailable:
            return "Аудио-выход недоступен. Выберите другое устройство в Настройках."
        case .noDataFromServer:
            // The watchdog only fires now when literally no mic
            // frames flowed AND no server delta arrived. That's a
            // mic-side problem 99% of the time (engine didn't spin
            // up, permission revoked mid-session, USB device
            // unplugged). Server-side stalls would surface via the
            // reconnect path with .networkLost.
            return "Микрофон не подаёт сигнал. Проверьте, что выбрано правильное устройство в Настройках, и попробуйте снова."
        case .audioCaptureDenied:
            return "Нет доступа к захвату системного звука. Откройте Настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → Только запись системного звука."
        }
    }
}
