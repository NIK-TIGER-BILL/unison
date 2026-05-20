import SwiftUI

/// Canonical Unison logo as a SwiftUI `Shape`.
///
/// Source: `design/logo-final/index.html` `<symbol id="logo-unison">`
/// (`viewBox 0 0 256 256`).
///
/// Coordinates from the master SVG, mapped from the 256-unit design space
/// to the actual rect of the shape (aspect-fit, centred):
///
/// - U body: `M82 66 V146 C82 177.5 102.5 198 128 198 C153.5 198 174 177.5 174 146 V66`
/// - Inner left bar:  `M58 86 V136`
/// - Outer left bar:  `M38 102 V126`
/// - Inner right bar: `M198 86 V136`
/// - Outer right bar: `M218 102 V126`
///
/// Stroke this shape (`.stroke(lineWidth:lineJoin:lineCap:)`) — the
/// shape itself does not fill. Pair with `.aspectRatio(1, contentMode: .fit)`
/// at the call site to preserve square proportions. Set
/// `showVoiceStreams = false` for the `paused` menubar state (the four
/// side bars vanish, only the U remains).
public struct UnisonLogoShape: Shape {
    /// Side ear-bars are drawn when `true`. Disable for the `paused`
    /// variant where "the voice streams have fallen silent".
    public var showVoiceStreams: Bool

    public init() {
        self.init(showVoiceStreams: true)
    }

    public init(showVoiceStreams: Bool) {
        self.showVoiceStreams = showVoiceStreams
    }

    public func path(in rect: CGRect) -> Path {
        let designSize: CGFloat = 256

        // Aspect-fit the 256×256 design space into `rect`, centred.
        let scale = min(rect.width, rect.height) / designSize
        let drawnSize = designSize * scale
        let offsetX = rect.minX + (rect.width - drawnSize) / 2
        let offsetY = rect.minY + (rect.height - drawnSize) / 2

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: offsetX + x * scale, y: offsetY + y * scale)
        }

        var path = Path()

        // ── U letter ──────────────────────────────────────────────
        // M82 66 V146  → vertical line down the left side of U
        // C82 177.5 102.5 198 128 198  → bottom-left curve to midpoint
        // C153.5 198 174 177.5 174 146 → bottom-right curve up to right top
        // V66 → vertical line up the right side
        path.move(to: p(82, 66))
        path.addLine(to: p(82, 146))
        path.addCurve(
            to: p(128, 198),
            control1: p(82, 177.5),
            control2: p(102.5, 198)
        )
        path.addCurve(
            to: p(174, 146),
            control1: p(153.5, 198),
            control2: p(174, 177.5)
        )
        path.addLine(to: p(174, 66))

        if showVoiceStreams {
            // ── Left voice streams ────────────────────────────────
            path.move(to: p(58, 86))
            path.addLine(to: p(58, 136))

            path.move(to: p(38, 102))
            path.addLine(to: p(38, 126))

            // ── Right voice streams ───────────────────────────────
            path.move(to: p(198, 86))
            path.addLine(to: p(198, 136))

            path.move(to: p(218, 102))
            path.addLine(to: p(218, 126))
        }

        return path
    }
}
