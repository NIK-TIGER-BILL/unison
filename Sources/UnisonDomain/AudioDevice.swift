public struct AudioDevice: Sendable, Hashable {
    public enum Kind: Sendable { case input, output }

    public let uid: String
    public let name: String
    public let kind: Kind

    public init(uid: String, name: String, kind: Kind) {
        self.uid = uid
        self.name = name
        self.kind = kind
    }

    public static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
    }
}
