import SwiftUI
import UnisonDomain

/// Renders a stack of `BubbleGroup`s with the design-spec gaps:
/// `14pt × scale` between groups, `3pt × scale` between bubbles inside a
/// group. DESIGN.md §5.14.
public struct BubbleGroupView: View {
    public let groups: [BubbleGroup]
    public let scale: Double

    public init(groups: [BubbleGroup], scale: Double = 1.0) {
        self.groups = groups
        self.scale = scale
    }

    public var body: some View {
        // We emit a flat VStack and selectively pad each bubble's top so the
        // 14pt-between-group / 3pt-within-group rule lines up.
        VStack(spacing: 0) {
            ForEach(Array(flatten().enumerated()), id: \.element.bubble.id) { offset, item in
                Bubble(
                    speaker: item.bubble.speaker,
                    primary: item.bubble.primaryText,
                    secondary: item.bubble.secondaryText,
                    isContinued: !item.bubble.isFirstInGroup,
                    isLastInGroup: item.bubble.isLastInGroup,
                    isLive: item.bubble.isLive,
                    scale: scale
                )
                .padding(.top, offset == 0
                    ? 0
                    : (item.isGroupBoundary ? 14 * scale : 3 * scale))
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.93))
                        .animation(UnisonAnimations.bubbleIn),
                    removal: .opacity.animation(.easeOut(duration: 0.7))
                ))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct FlatBubble {
        let bubble: BubbleViewModel
        let isGroupBoundary: Bool
    }

    private func flatten() -> [FlatBubble] {
        var out: [FlatBubble] = []
        for (groupIdx, group) in groups.enumerated() {
            for (bubbleIdx, bubble) in group.bubbles.enumerated() {
                let boundary = groupIdx > 0 && bubbleIdx == 0
                out.append(FlatBubble(bubble: bubble, isGroupBoundary: boundary))
            }
        }
        return out
    }
}

