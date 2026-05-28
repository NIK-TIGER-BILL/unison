import Foundation
import UnisonDomain
@testable import UnisonUI

// Local mocks for snapshot tests — kept here so the test target is
// independent of `UnisonDomainTests/Mocks`. Each mock is tiny because
// we only need the surface area the views read in the snapshot.

final class PreviewPermissions: PermissionsService, @unchecked Sendable {
    var statuses: [PermissionKind: PermissionStatus] = [:]

    func currentStatus(_ kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .granted
    }
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        statuses[kind] ?? .granted
    }
    func openSystemSettings(for kind: PermissionKind) {}
}

final class PreviewInstaller: BlackHoleInstaller, @unchecked Sendable {
    var installed2ch = true
    func is2chInstalled() -> Bool { installed2ch }
    func runBundledInstaller() async throws {}
}

final class PreviewKeychain: KeychainService, @unchecked Sendable {
    var stored: String?
    func loadAPIKey() -> String? { stored }
    func saveAPIKey(_ key: String) throws { stored = key }
    func deleteAPIKey() throws { stored = nil }
}

final class PreviewDeviceRegistry: AudioDeviceRegistry, @unchecked Sendable {
    var inputs: [AudioDevice] = []
    var outputs: [AudioDevice] = []
    var bh2ch: AudioDevice? = AudioDevice(uid: "BlackHole2ch", name: "BlackHole 2ch", kind: .input)
    let deviceChanges: AsyncStream<Void>

    init() {
        var c: AsyncStream<Void>.Continuation!
        self.deviceChanges = AsyncStream { c = $0 }
        _ = c
    }

    func availableInputDevices() -> [AudioDevice] { inputs }
    func availableOutputDevices() -> [AudioDevice] { outputs }
    func findBlackHole2ch() -> AudioDevice? { bh2ch }
}
