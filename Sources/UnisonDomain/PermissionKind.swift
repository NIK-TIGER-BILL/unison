public enum PermissionKind: String, CaseIterable, Codable, Sendable {
    case microphone
}

public enum PermissionStatus: Sendable {
    case notDetermined
    case granted
    case denied
}
