import Foundation
import Observation
import os
import UnisonDomain

public enum StartBlockedReason: Equatable, Sendable {
    case micPermissionRequired
    case blackHole2chMissing
    case blackHole16chMissing
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
    /// `os.Logger` channel for the popover view-model. Stream this with
    /// `log stream --predicate 'subsystem == "com.unison.app"' --info`
    /// to see exactly which step of `start()` is reached (or skipped)
    /// when a click on "Начать перевод" appears to do nothing.
    @ObservationIgnored
    static let log = Logger(subsystem: "com.unison.app", category: "PopoverVM")

    private let orchestrator: TranslationOrchestrator?
    private let permissions: any PermissionsService
    private let deviceRegistry: any AudioDeviceRegistry
    public var settings: Settings

    /// Test-only override for the session state. When the VM is
    /// constructed via `previewing(...)` the state is sourced from this
    /// property instead of an orchestrator. Production code never
    /// touches this — `orchestrator.state` always wins when it exists.
    public var previewState: SessionState = .idle

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
        deviceRegistry: any AudioDeviceRegistry
    ) -> PopoverViewModel {
        PopoverViewModel(
            permissions: permissions,
            deviceRegistry: deviceRegistry,
            settings: settings,
            previewState: state
        )
    }

    public var state: SessionState { orchestrator?.state ?? previewState }

    public var languagePairDisplay: String {
        let mine = settings.languagePair.mine
        let peer = settings.languagePair.peer
        return "\(mine.flagEmoji) \(mine.displayName) → \(peer.flagEmoji) \(peer.displayName)"
    }

    public var runningTimeSeconds: TimeInterval {
        if case .translating(_, let startedAt) = state {
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

    /// Visual status for the header dot.
    /// - `.error` while the orchestrator is in `.error`
    /// - `.active` while connecting / translating / reconnecting
    /// - `.warn` when the language pair is invalid
    /// - `.ready` otherwise
    public var statusKind: StatusKind {
        if case .error = state { return .error }
        if state.isActive { return .active }
        if !isLanguagePairValid { return .warn }
        return .ready
    }

    /// Status-dot kind, decoupled from `StatusDot.State` so consumers
    /// (and tests) don't pull in SwiftUI.
    public enum StatusKind: Equatable, Sendable {
        case ready
        case active
        case warn
        case error
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
        if settings.sessionMode == .call,
           permissions.currentStatus(.microphone) == .denied {
            return .micPermissionRequired
        }
        if settings.sessionMode == .call, deviceRegistry.findBlackHole2ch() == nil {
            return .blackHole2chMissing
        }
        if deviceRegistry.findBlackHole16ch() == nil {
            return .blackHole16chMissing
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
        let bh16 = deviceRegistry.findBlackHole16ch() != nil
        let preState = String(describing: state)
        Self.log.info("start() called — mode=\(mode.rawValue, privacy: .public), pair=\(mineCode, privacy: .public)→\(peerCode, privacy: .public)")
        Self.log.info("start() pre-flight — blockedReason=\(blocked, privacy: .public), mic=\(micStatus, privacy: .public), BH2ch=\(bh2 ? "present" : "missing", privacy: .public), BH16ch=\(bh16 ? "present" : "missing", privacy: .public), state=\(preState, privacy: .public)")

        if orchestrator == nil {
            Self.log.error("start() — orchestrator is nil (preview VM); skipping")
            return
        }

        await orchestrator?.start(mode: mode, languages: settings.languagePair, settings: settings)
        let postState = String(describing: state)
        Self.log.info("start() returned — state=\(postState, privacy: .public)")
    }

    public func stop() async {
        Self.log.info("stop() called — state=\(String(describing: self.state), privacy: .public)")
        await orchestrator?.stop()
        Self.log.info("stop() returned — state=\(String(describing: self.state), privacy: .public)")
    }

    /// Toggle between Call and Listen modes. Convenience for the view.
    public func toggleSessionMode() {
        settings.sessionMode = settings.sessionMode == .call ? .listen : .call
    }

    /// Replace the current language pair. Centralising the write keeps
    /// the view layer from poking at `settings.languagePair` directly.
    public func updateLanguagePair(_ pair: LanguagePair) {
        settings.languagePair = pair
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
        case .blackHole16chMissing:
            return "BlackHole 16ch не найден. Установите драйвер в Onboarding."
        case .networkLost:
            return "Нет связи с серверами OpenAI. Проверьте интернет."
        case .apiKeyInvalid:
            return "Ключ OpenAI отклонён. Проверьте в Настройках."
        case .rateLimited:
            return "Превышен лимит запросов OpenAI. Повторите позже."
        case .insufficientCredits:
            return "Закончились средства OpenAI. Пополните баланс."
        case .inputDeviceUnavailable:
            return "Микрофон недоступен. Выберите другое устройство в Настройках."
        case .outputDeviceUnavailable:
            return "Аудио-выход недоступен. Выберите другое устройство в Настройках."
        }
    }
}
