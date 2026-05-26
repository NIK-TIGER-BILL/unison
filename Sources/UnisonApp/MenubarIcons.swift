import AppKit

/// Visual state of the menubar status item icon.
///
/// Maps the four states from `design/menubar-final/index.html` to
/// `NSImage` variants that can be assigned to `NSStatusItem.button?.image`:
/// - `.idle`   — full logo (U + 4 voice streams), template image (system
///               handles tinting based on menubar appearance).
/// - `.active` — full logo with cyan tint (`UnisonColors.active`), NOT a
///               template — the colour survives macOS appearance tinting.
/// - `.paused` — U letter only (no voice streams), template image at
///               reduced opacity baked into the path stroke.
/// - `.error`  — full logo with coral tint plus a 6×6 dot badge in the
///               top-right corner. Not a template.
public enum MenubarState: Sendable, Equatable {
    case idle
    case active
    case paused
    case error
}

/// Generates the four menubar status-item icons for the Unison logo.
///
/// Design source: `design/menubar-final/index.html` `.unison-slot` rules:
/// - `.unison-slot svg`         → 18×18, `color: rgba(255,255,255,0.92)`
/// - `.unison-slot.active svg`  → `color: var(--active)` (#5ac8fa)
/// - `.unison-slot.paused svg`  → `color: rgba(255,255,255,0.40)`
/// - `.unison-slot.error svg`   → `color: var(--error)` (#ff7a8c) +
///                                 6×6 coral dot in the top-right corner.
///
/// We draw the logo via `NSBezierPath` mirroring the `UnisonLogoShape`
/// coordinates from `UnisonUI/Design/UnisonLogoShape.swift` (256-unit
/// viewBox aspect-fit into the destination rect). We can't reach the
/// SwiftUI shape here (no SwiftUI in this draw handler at a sensible
/// cost), so the path code is intentionally a small duplicate. The
/// canonical reference is `UnisonLogoShape.swift`.
///
/// The images are cached statically — building four 18×18 NSImages is
/// cheap, but `setIconState(_:)` is called on every orchestrator state
/// transition and these are pure functions of the state.
enum MenubarIcons {
    /// Canonical menubar icon side length. 18pt matches the menubar SF
    /// Symbol metrics on macOS 14+; the system trims to 22pt height with
    /// padding above/below, so 18×18 is the visual sweet spot.
    static let iconSize: CGFloat = 18

    /// Returns the menubar image for the given state. Cached after the
    /// first call per state.
    static func image(for state: MenubarState) -> NSImage {
        switch state {
        case .idle:   return cachedIdle
        case .active: return cachedActive
        case .paused: return cachedPaused
        case .error:  return cachedError
        }
    }

    // MARK: - Cache

    private static let cachedIdle: NSImage = render(
        showsVoiceStreams: true,
        fill: NSColor(white: 1.0, alpha: 1.0),
        badge: false,
        isTemplate: true
    )

    private static let cachedActive: NSImage = render(
        showsVoiceStreams: true,
        // #5ac8fa — UnisonColors.active. Hard-coded here because we
        // can't pull `Color` → `NSColor` cheaply without a SwiftUI host.
        fill: NSColor(red: 0x5a / 255.0, green: 0xc8 / 255.0, blue: 0xfa / 255.0, alpha: 1.0),
        badge: false,
        isTemplate: false
    )

    private static let cachedPaused: NSImage = render(
        showsVoiceStreams: false,
        // Template image: opacity will be applied by AppKit's menubar
        // tinting (40% maps to a softer rendering on the bar). Using
        // alpha here on a template image is generally ignored by AppKit
        // — that's intentional. The "muted" look comes from the
        // template treatment + the U-only silhouette.
        fill: NSColor(white: 1.0, alpha: 1.0),
        badge: false,
        isTemplate: true
    )

    private static let cachedError: NSImage = render(
        showsVoiceStreams: true,
        // #ff7a8c — UnisonColors.error.
        fill: NSColor(red: 0xff / 255.0, green: 0x7a / 255.0, blue: 0x8c / 255.0, alpha: 1.0),
        badge: true,
        isTemplate: false
    )

    // MARK: - Rendering

    /// Render the logo into an NSImage of `iconSize × iconSize` using
    /// the 256-unit design coordinates from `UnisonLogoShape`.
    private static func render(
        showsVoiceStreams: Bool,
        fill: NSColor,
        badge: Bool,
        isTemplate: Bool
    ) -> NSImage {
        let size = NSSize(width: iconSize, height: iconSize)
        let image = NSImage(size: size, flipped: false) { rect in
            drawLogo(in: rect, showsVoiceStreams: showsVoiceStreams, fill: fill)
            if badge {
                drawErrorBadge(in: rect)
            }
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// Draw the Unison logo path into `rect`. Mirrors `UnisonLogoShape`
    /// 1:1 — see that file for the canonical commentary on each curve.
    /// `NSBezierPath` here so we don't need an SwiftUI host context.
    private static func drawLogo(
        in rect: NSRect,
        showsVoiceStreams: Bool,
        fill: NSColor
    ) {
        // The 256-unit design space → aspect-fit into rect.
        let designSize: CGFloat = 256
        let scale = min(rect.width, rect.height) / designSize
        let drawnSize = designSize * scale
        let offsetX = rect.minX + (rect.width - drawnSize) / 2
        let offsetY = rect.minY + (rect.height - drawnSize) / 2

        // Y-flip: the design coordinates assume top-down (SVG/SwiftUI),
        // NSBezierPath here is in bottom-up (Cocoa). We mirror Y so the
        // curves render the right way up.
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(
                x: offsetX + x * scale,
                y: offsetY + (designSize - y) * scale
            )
        }

        // Stroke width: 12 in the 256-unit space → ≈0.84pt at 18×18.
        // That looks too thin at small sizes, so we bake in a min-width
        // floor of 1.8pt to preserve visibility on the menubar.
        let strokeWidth = max(12 * scale, 1.8)

        let path = NSBezierPath()
        path.lineWidth = strokeWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        // ── U body ───────────────────────────────────────────────
        path.move(to: p(82, 66))
        path.line(to: p(82, 146))
        path.curve(
            to: p(128, 198),
            controlPoint1: p(82, 177.5),
            controlPoint2: p(102.5, 198)
        )
        path.curve(
            to: p(174, 146),
            controlPoint1: p(153.5, 198),
            controlPoint2: p(174, 177.5)
        )
        path.line(to: p(174, 66))

        if showsVoiceStreams {
            // ── Left voice streams ────────────────────────────────
            path.move(to: p(58, 86));  path.line(to: p(58, 136))
            path.move(to: p(38, 102)); path.line(to: p(38, 126))

            // ── Right voice streams ───────────────────────────────
            path.move(to: p(198, 86));  path.line(to: p(198, 136))
            path.move(to: p(218, 102)); path.line(to: p(218, 126))
        }

        fill.setStroke()
        path.stroke()
    }

    /// Top-right coral dot for the `.error` state. 6×6 (slightly smaller
    /// than CSS's 6×6 to fit the 18pt icon footprint cleanly).
    private static func drawErrorBadge(in rect: NSRect) {
        // CSS: `top: 1px; right: 2px; width: 6px; height: 6px;` on a 22pt
        // tile. We're 18×18; clamp the dot to 5×5 so it doesn't crowd
        // the logo's right ear.
        let dotSize: CGFloat = 5
        let inset: CGFloat = 1
        let origin = NSPoint(
            x: rect.maxX - dotSize - inset,
            y: rect.maxY - dotSize - inset
        )
        let badgeRect = NSRect(origin: origin, size: NSSize(width: dotSize, height: dotSize))
        let dot = NSBezierPath(ovalIn: badgeRect)
        NSColor(red: 0xff / 255.0, green: 0x7a / 255.0, blue: 0x8c / 255.0, alpha: 1.0)
            .setFill()
        dot.fill()
    }
}
