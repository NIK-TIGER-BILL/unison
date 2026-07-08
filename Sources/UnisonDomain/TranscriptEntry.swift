import Foundation

public enum Speaker: String, Sendable, Codable { case me, peer }

public struct TranscriptEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let speaker: Speaker
    public var originalText: String?
    public var translatedText: String
    public let sourceLanguage: Language?
    public let targetLanguage: Language
    public let timestamp: Date
    /// Time of the most recent delta folded into this entry. Defaults to
    /// `timestamp` (creation). Bumped by `TranscriptStore.apply`. Drives
    /// the transcript recency window so a long continuous utterance (one
    /// entry, many deltas) stays visible while still being spoken, and a
    /// finished one lingers for the window after its *last* delta.
    public var lastActivityAt: Date
    /// True when the orchestrator transitioned through `.paused` /
    /// `.reconnecting` while this entry was still accumulating
    /// deltas. Used by `BubbleViewModel.translationLost` to decide
    /// whether to render the "перевод не получен" placeholder. A
    /// late-arriving translation delta clears this flag (see
    /// `TranscriptStore.apply`).
    public var translationAtRisk: Bool
    /// Set when the user edits this entry's text in the meeting archive.
    /// Persisted with the record; ignored by the live transcript.
    public var edited: Bool

    public init(
        id: UUID, speaker: Speaker,
        originalText: String? = nil, translatedText: String,
        sourceLanguage: Language?, targetLanguage: Language,
        timestamp: Date,
        lastActivityAt: Date? = nil,
        translationAtRisk: Bool = false,
        edited: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.lastActivityAt = lastActivityAt ?? timestamp
        self.translationAtRisk = translationAtRisk
        self.edited = edited
    }
}

public struct TranscriptDelta: Sendable, Equatable {
    public enum Kind: String, Sendable { case original, translated }

    public let entryId: UUID
    public let speaker: Speaker
    public let kind: Kind
    public let text: String
    public let isFinal: Bool
    /// BCP-47-derived language of this chunk (source language for `.original`,
    /// target for `.translated`), when the stream reports it. Drives
    /// language-aware sentence segmentation downstream.
    public let language: Language?

    public init(entryId: UUID, speaker: Speaker, kind: Kind, text: String,
                isFinal: Bool, language: Language? = nil) {
        self.entryId = entryId
        self.speaker = speaker
        self.kind = kind
        self.text = text
        self.isFinal = isFinal
        self.language = language
    }
}
