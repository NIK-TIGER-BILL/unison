import Foundation
@testable import UnisonDomain

public final class MockPermissionsService: PermissionsService, @unchecked Sendable {
    public var statuses: [PermissionKind: PermissionStatus] = [:]
    public var requestCalls: [PermissionKind] = []
    public var openSettingsCalls: [PermissionKind] = []

    public init() {}
    public func currentStatus(_ kind: PermissionKind) -> PermissionStatus {
        statuses[kind] ?? .notDetermined
    }
    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        requestCalls.append(kind)
        return statuses[kind] ?? .granted
    }
    public func openSystemSettings(for kind: PermissionKind) {
        openSettingsCalls.append(kind)
    }
}
