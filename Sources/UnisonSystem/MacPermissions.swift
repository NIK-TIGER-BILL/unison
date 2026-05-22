import Foundation
import AVFoundation
import AppKit
import UnisonDomain

public final class MacPermissions: PermissionsService, @unchecked Sendable {
    public init() {}

    /// Test-only escape hatch. `UNISON_MOCK_PERMISSION_GRANTED=microphone`
    /// (or `=microphone,…` once more kinds exist) returns `.granted`
    /// without ever touching TCC. Used by the VM integration suite —
    /// TCC entries are bound to the code-signature hash, which changes
    /// every rebuild, so the script would otherwise hit
    /// notDetermined→denied on each fresh binary (no UI to consent).
    /// Production launches never set this env var.
    private static let mockedGrants: Set<PermissionKind> = {
        guard let raw = ProcessInfo.processInfo.environment["UNISON_MOCK_PERMISSION_GRANTED"],
              !raw.isEmpty else { return [] }
        var grants: Set<PermissionKind> = []
        for token in raw.split(separator: ",") {
            switch token.trimmingCharacters(in: .whitespaces) {
            case "microphone": grants.insert(.microphone)
            default: break
            }
        }
        return grants
    }()

    public func currentStatus(_ kind: PermissionKind) -> PermissionStatus {
        if Self.mockedGrants.contains(kind) { return .granted }
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined: return .notDetermined
            case .authorized: return .granted
            case .denied, .restricted: return .denied
            @unknown default: return .denied
            }
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        if Self.mockedGrants.contains(kind) { return .granted }
        switch kind {
        case .microphone:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .granted : .denied
        }
    }

    public func openSystemSettings(for kind: PermissionKind) {
        let url: String = switch kind {
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
        if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }
}
