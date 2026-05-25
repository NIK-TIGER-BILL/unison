import SwiftUI

/// Native SwiftUI `Slider` with a neutral white tint to match the
/// Unison palette (no system accent blue). On macOS 26 the system
/// supplies Liquid Glass styling — track, handle, hover, focus.
///
/// The original Unison "T2" custom slider rendered a 6pt track with a
/// 4×18 white capsule handle. We now defer to Apple's native control
/// and only override the tint. Two pure helpers — `fraction(of:in:)`
/// and `fillOpacity(for:)` — are kept on the type because tests and a
/// few callers depend on them.
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

    public var body: some View {
        // HIG Materials: vibrant `.secondary` for the small mono labels
        // that frame the slider on the popover / settings glass.
        HStack(spacing: 10) {
            if let leading = leadingLabel {
                Text(leading)
                    .font(UnisonFonts.mono(10.5))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
            sliderBody
            if let trailing = trailingLabel {
                Text(trailing)
                    .font(UnisonFonts.mono(10.5))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sliderBody: some View {
        if let step = step {
            Slider(value: $value, in: range, step: step)
                .tint(.white)
                .help(helpText)
        } else {
            Slider(value: $value, in: range)
                .tint(.white)
                .help(helpText)
        }
    }

    /// Hover tooltip — fraction-of-range as a percentage so the
    /// volume slider and the size slider both speak the same dialect.
    private var helpText: String {
        let fraction = Self.fraction(of: value, in: range)
        return "\(Int((fraction * 100).rounded()))%"
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
