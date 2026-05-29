import Foundation
import UnisonDomain

/// Single bubble's worth of presentation data, derived from one or more
/// `TranscriptEntry`s after splitting long messages at sentence boundaries.
public struct BubbleViewModel: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let primaryText: String
    public let secondaryText: String
    public let isFirstInGroup: Bool
    public let isLastInGroup: Bool
    public let isLive: Bool
    /// True when the source-language text exists but the translation
    /// never arrived AND the orchestrator transitioned through
    /// pause/reconnect during this entry's lifetime. Drives a grey
    /// italic placeholder in `Bubble.swift` where the translation
    /// would normally render.
    public let translationLost: Bool

    public init(
        id: UUID,
        speaker: Speaker,
        primaryText: String,
        secondaryText: String,
        isFirstInGroup: Bool,
        isLastInGroup: Bool,
        isLive: Bool,
        translationLost: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.isFirstInGroup = isFirstInGroup
        self.isLastInGroup = isLastInGroup
        self.isLive = isLive
        self.translationLost = translationLost
    }
}

/// A consecutive run of bubbles from the same speaker.
public struct BubbleGroup: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let bubbles: [BubbleViewModel]

    public init(id: UUID, speaker: Speaker, bubbles: [BubbleViewModel]) {
        self.id = id
        self.speaker = speaker
        self.bubbles = bubbles
    }
}
