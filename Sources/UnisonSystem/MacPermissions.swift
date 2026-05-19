import Foundation
import AVFoundation
import AppKit
import UnisonDomain

public final class MacPermissions: PermissionsService, @unchecked Sendable {
    public init() {}

    public func currentStatus(_ kind: PermissionKind) -> PermissionStatus {
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
