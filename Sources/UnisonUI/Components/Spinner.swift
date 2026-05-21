import SwiftUI

/// Indeterminate circular progress spinner.
///
/// A 70% arc that rotates linearly at 0.85s/turn — matches the inline
/// spinner CSS used by primary buttons across the design.
///
/// Centralised so `PrimaryGlassButton`, `InlineButton`, and any future
/// loading affordance render the same shape and tempo.
public struct Spinner: View {
    public let size: CGFloat
    public let lineWidth: CGFloat
    public let color: Color

    public init(
        size: CGFloat = 12,
        lineWidth: CGFloat = 1.5,
        color: Color = .white
    ) {
        self.size = size
        self.lineWidth = lineWidth
        self.color = color
    }

    @SwiftUI.State private var angle: Double = 0

    public var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(color, lineWidth: lineWidth)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 0.85).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
