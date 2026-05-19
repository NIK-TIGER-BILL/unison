public enum SessionMode: String, CaseIterable, Codable, Sendable {
    case call
    case listen

    public var requiresMicrophone: Bool {
        switch self {
        case .call: true
        case .listen: false
        }
    }
}
