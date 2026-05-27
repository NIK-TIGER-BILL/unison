public enum SessionMode: String, CaseIterable, Codable, Sendable {
    /// Real call. Mic → translated → BlackHole 2ch (virtual mic in
    /// peer's Zoom). Peer audio (via Process Tap) → translated → speakers.
    case call
    /// Passive listen. No mic. Peer audio (via Process Tap) → translated
    /// → speakers. Used when you're consuming a podcast / video in a
    /// foreign language and just want to hear your own language.
    case listen
    /// Self-test. Mic → translated → speakers (you hear your own
    /// translated voice locally). Doesn't touch BlackHole at all,
    /// so it works without the BH driver installed. Used to verify
    /// translation works before joining a real call.
    case test

    public var requiresMicrophone: Bool {
        switch self {
        case .call, .test: true
        case .listen: false
        }
    }
}
