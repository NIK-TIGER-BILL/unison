import Foundation

public enum Speaker: String, Sendable, Codable { case me, peer }

public struct TranscriptEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let speaker: Speaker
    public var originalText: String?
    public var translatedText: String
    public let sourceLanguage: Language?
    public let targetLanguage: Language
    public let timestamp: Date

    public init(
        id: UUID, speaker: Speaker,
        originalText: String? = nil, translatedText: String,
        sourceLanguage: Language?, targetLanguage: Language,
        timestamp: Date
    ) {
        self.id = id
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
    }
}

public struct TranscriptDelta: Sendable, Equatable {
    public enum Kind: String, Sendable { case original, translated }

    public let entryId: UUID
    public let speaker: Speaker
    public let kind: Kind
    public let text: String
    public let isFinal: Bool

    public init(entryId: UUID, speaker: Speaker, kind: Kind, text: String, isFinal: Bool) {
        self.entryId = entryId
        self.speaker = speaker
        self.kind = kind
        self.text = text
        self.isFinal = isFinal
    }
}
