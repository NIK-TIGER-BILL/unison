import SwiftUI

/// T2 vertical-handle slider. Neutral white-on-glass treatment, no system
/// blue. Track is 6pt tall, handle is a 4×18 white capsule that grows to
/// 20pt on hover. Fill brightness scales with value (`0.12 → 0.85`).
/// DESIGN.md §5.13.
public struct NeutralSlider: View {
    @Binding public var value: Double
    public let range: ClosedRange<Double>
    public let step: Double?
    public let leadingLabel: String?
    public let trailingLabel: String?

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double? = nil,
        leadingLabel: String? = nil,
        trailingLabel: String? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.leadingLabel = leadingLabel
        self.trailingLabel = trailingLabel
    }

    @SwiftUI.State private var hovering = false

    public var body: some View {
        HStack(spacing: 10) {
            if let leading = leadingLabel {
                Text(leading)
                    .font(UnisonFonts.mono(10.5))
                    .tracking(0.4)
                    .foregroundStyle(UnisonColors.whiteAlpha(0.45))
            }
            sliderBody
            if let trailing = trailingLabel {
                Text(trailing)
                    .font(UnisonFonts.mono(10.5))
                    .tracking(0.4)
                    .foregroundStyle(UnisonColors.whiteAlpha(0.45))
            }
        }
    }

    private var sliderBody: some View {
        GeometryReader { geo in
            let trackWidth = geo.size.width
            let fraction = Self.fraction(of: value, in: range)
            let opacity = Self.fillOpacity(for: fraction)
            let handleX = trackWidth * fraction
            ZStack(alignment: .leading) {
                // Right portion (unfilled).
                Capsule()
                    .fill(UnisonColors.whiteAlpha(0.10))
                    .frame(height: 6)
                // Left portion (fill, brightness derived from fraction).
                Capsule()
                    .fill(UnisonColors.whiteAlpha(opacity))
                    .frame(width: handleX, height: 6)
                // Vertical handle.
                Capsule()
                    .fill(LinearGradient(
                        colors: [.white, Color(red: 221 / 255, green: 221 / 255, blue: 221 / 255)],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(width: 4, height: hovering ? 20 : 18)
                    .shadow(color: .black.opacity(0.55), radius: hovering ? 3 : 2, x: 0, y: 2)
                    .offset(x: max(0, min(handleX - 2, trackWidth - 4)))
                    .animation(.easeOut(duration: 0.14), value: hovering)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let f = max(0.0, min(1.0, drag.location.x / trackWidth))
                        let raw = range.lowerBound + Double(f) * (range.upperBound - range.lowerBound)
                        if let step = step {
                            let stepped = (raw / step).rounded() * step
                            value = min(range.upperBound, max(range.lowerBound, stepped))
                        } else {
                            value = min(range.upperBound, max(range.lowerBound, raw))
                        }
                    }
            )
            .onHover { hovering = $0 }
        }
        .frame(height: 22) // accommodates the 20pt hover handle + breathing room
    }

    // MARK: - Pure helpers (tested separately)

    /// Maps a `value` in `range` to a `0...1` fraction.
    public nonisolated static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        let raw = (value - range.lowerBound) / span
        return min(1.0, max(0.0, raw))
    }

    /// Fill opacity formula from `design/transcript-final/index.html`:
    /// `opacity = 0.12 + fraction * 0.73`. Clamped to `[0, 1]`.
    public nonisolated static func fillOpacity(for fraction: Double) -> Double {
        let clamped = min(1.0, max(0.0, fraction))
        return 0.12 + clamped * 0.73
    }
}

