import SwiftUI

/// Half-point dashed horizontal divider.
///
/// SwiftUI's `Divider` does not support dashed strokes, so we stroke a
/// single horizontal `Path` at the full available width. Used inside
/// onboarding `StepCard` blocks to separate the hint row from the
/// action button, matching the design's `border-top: 0.5px dashed`.
public struct DashedDivider: View {
    public let color: Color
    public let dash: [CGFloat]

    public init(
        color: Color = UnisonColors.whiteAlpha(0.08),
        dash: [CGFloat] = [3, 3]
    ) {
        self.color = color
        self.dash = dash
    }

    public var body: some View {
        GeometryReader { proxy in
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0.25))
                p.addLine(to: CGPoint(x: proxy.size.width, y: 0.25))
            }
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 0.5, dash: dash)
            )
        }
        .frame(height: 0.5)
    }
}
