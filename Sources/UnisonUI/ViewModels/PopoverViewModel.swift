import Foundation
import Observation
import UnisonDomain

public enum StartBlockedReason: Equatable, Sendable {
    case micPermissionRequired
    case blackHole2chMissing
    case blackHole16chMissing
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
        return "\(flag(mine)) \(mine.displayName) → \(flag(peer)) \(peer.displayName)"
    }

    public var runningTimeSeconds: TimeInterval {
        if case .translating(_, let startedAt) = orchestrator.state {
            return Date().timeIntervalSince(startedAt)
        }
        return 0
    }

    public var canStart: Bool { startBlockedReason == nil }

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

    private func flag(_ lang: Language) -> String {
        switch lang {
        case .ru: "🇷🇺"; case .en: "🇬🇧"; case .es: "🇪🇸"; case .fr: "🇫🇷"
        case .de: "🇩🇪"; case .it: "🇮🇹"; case .pt: "🇵🇹"; case .zh: "🇨🇳"
        case .ja: "🇯🇵"; case .ko: "🇰🇷"
        }
    }
}
