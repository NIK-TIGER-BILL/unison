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

    // Identity is (uid, kind), not uid alone: CoreAudio UIDs are
    // per-device, not per-direction, and duplex devices (BlackHole 2ch
    // itself) legitimately appear once as input and once as output —
    // a uid-only identity silently collapses the two in any Set /
    // Dictionary / diff over a mixed collection. `name` stays out of
    // the identity on purpose (it's display-only and localizable).
    public static func == (lhs: AudioDevice, rhs: AudioDevice) -> Bool {
        lhs.uid == rhs.uid && lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(uid)
        hasher.combine(kind)
    }
}
