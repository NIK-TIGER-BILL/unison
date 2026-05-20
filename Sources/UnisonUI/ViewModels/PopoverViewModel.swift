import Foundation
import Observation
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
    private let orchestrator: TranslationOrchestrator
    private let permissions: any PermissionsService
    private let deviceRegistry: any AudioDeviceRegistry
    public var settings: Settings

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

    public var state: SessionState { orchestrator.state }

    public var languagePairDisplay: String {
        let mine = settings.languagePair.mine
        let peer = settings.languagePair.peer
        return "\(mine.flagEmoji) \(mine.displayName) → \(peer.flagEmoji) \(peer.displayName)"
    }

    public var runningTimeSeconds: TimeInterval {
        if case .translating(_, let startedAt) = orchestrator.state {
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
        if case .error = orchestrator.state { return .error }
        if orchestrator.state.isActive { return .active }
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
        orchestrator.state.isActive ? "Остановить" : "Начать перевод"
    }

    /// Icon for the primary action button.
    public var primaryButtonIcon: PopoverPrimaryIcon {
        orchestrator.state.isActive ? .stop : .play
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
        await orchestrator.start(mode: settings.sessionMode, languages: settings.languagePair, settings: settings)
    }

    public func stop() async {
        await orchestrator.stop()
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
}
