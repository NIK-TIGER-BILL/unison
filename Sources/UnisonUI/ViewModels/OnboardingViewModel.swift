import Foundation
import Observation
import UnisonDomain

public enum OnboardingStepKind: Sendable {
    case blackHole
    case microphone
    case apiKey
}

public struct OnboardingStep: Identifiable, Sendable {
    public let id = UUID()
    public let kind: OnboardingStepKind
    public let title: String
    public let isDone: Bool
}

@MainActor
@Observable
public final class OnboardingViewModel {
    private let permissions: any PermissionsService
    private let installer: any BlackHoleInstaller
    private let keychain: any KeychainService

    public private(set) var steps: [OnboardingStep] = []

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
            OnboardingStep(kind: .blackHole, title: "Аудиодрайвер BlackHole", isDone: bhDone),
            OnboardingStep(kind: .microphone, title: "Доступ к микрофону", isDone: micDone),
            OnboardingStep(kind: .apiKey, title: "API ключ OpenAI", isDone: keyDone),
        ]
    }

    public var allDone: Bool { steps.allSatisfy(\.isDone) }

    public func installBlackHole() async throws {
        try await installer.runBundledInstaller()
        refresh()
    }

    public func requestMicPermission() async {
        _ = await permissions.request(.microphone)
        refresh()
    }

    public func saveAPIKey(_ key: String) throws {
        try keychain.saveAPIKey(key)
        refresh()
    }
}
