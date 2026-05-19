public struct LanguagePair: Equatable, Hashable, Codable, Sendable {
    public let mine: Language
    public let peer: Language

    public init(mine: Language, peer: Language) {
        self.mine = mine
        self.peer = peer
    }

    public static let `default` = LanguagePair(mine: .ru, peer: .en)

    public var swapped: LanguagePair {
        LanguagePair(mine: peer, peer: mine)
    }
}
