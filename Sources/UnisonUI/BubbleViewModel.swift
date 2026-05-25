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

    public init(
        id: UUID,
        speaker: Speaker,
        primaryText: String,
        secondaryText: String,
        isFirstInGroup: Bool,
        isLastInGroup: Bool,
        isLive: Bool
    ) {
        self.id = id
        self.speaker = speaker
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.isFirstInGroup = isFirstInGroup
        self.isLastInGroup = isLastInGroup
        self.isLive = isLive
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
