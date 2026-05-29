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
    /// True when the orchestrator transitioned through `.paused` /
    /// `.reconnecting` while this entry was still accumulating
    /// deltas. Used by `BubbleViewModel.translationLost` to decide
    /// whether to render the "перевод не получен" placeholder. A
    /// late-arriving translation delta clears this flag (see
    /// `TranscriptStore.apply`).
    public var translationAtRisk: Bool

    public init(
        id: UUID, speaker: Speaker,
        originalText: String? = nil, translatedText: String,
        sourceLanguage: Language?, targetLanguage: Language,
        timestamp: Date,
        translationAtRisk: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.translationAtRisk = translationAtRisk
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
