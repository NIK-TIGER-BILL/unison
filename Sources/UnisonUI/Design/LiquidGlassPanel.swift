import SwiftUI

/// Apply the canonical Aurora Liquid Glass material to a view.
///
/// Approximates the CSS `.glass` primitive (DESIGN.md §1.4):
/// dark tint over a `Material` blur, with a top specular highlight,
/// a conic angular-gradient rim, a soft drop shadow, and a hairline
/// white border. The original CSS uses `feDisplacementMap` for refractive
/// distortion — SwiftUI/AppKit have no equivalent at acceptable cost,
/// so the displacement is intentionally omitted (DESIGN.md §10.3 already
/// flags graceful fallback).
///
/// Usage:
/// ```swift
/// VStack { … }
///     .liquidGlass(cornerRadius: 14)
/// ```
public struct LiquidGlassPanel: ViewModifier {
    public let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // 1. Native macOS blur (vibrancy is provided by SwiftUI's
                    //    Material; on macOS this is an NSVisualEffectView).
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.regularMaterial)

                    // 2. Dark tint — `rgba(20, 22, 30, 0.55)`.
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(red: 20 / 255, green: 22 / 255, blue: 30 / 255).opacity(0.55))

                    // 3. Top specular highlight — `white 0.16` → clear.
                    LinearGradient(
                        colors: [
                            UnisonColors.whiteAlpha(0.16),
                            .clear,
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .blendMode(.screen)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            )
            // 4. Conic rim — angular gradient masked to a 1pt-thick border.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                UnisonColors.whiteAlpha(0.45),
                                UnisonColors.whiteAlpha(0.05),
                                UnisonColors.whiteAlpha(0.35),
                                UnisonColors.whiteAlpha(0.05),
                                UnisonColors.whiteAlpha(0.45),
                            ],
                            center: .center,
                            angle: .degrees(120)
                        ),
                        lineWidth: 1
                    )
                    .opacity(0.5)
            )
            // 5. Hairline base border — `white 0.13` 0.5pt.
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(UnisonColors.whiteAlpha(0.13), lineWidth: 0.5)
            )
            // 6. Drop shadow — `0 16 36 rgba(0,0,0,0.5)` from DESIGN §1.4.
            .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 16)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

public extension View {
    /// Wrap this view in the Unison liquid-glass panel material.
    /// - Parameter cornerRadius: 22–26 for main panels (popover/window),
    ///   12–14 for inner blocks per DESIGN.md §4.2.
    func liquidGlass(cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidGlassPanel(cornerRadius: cornerRadius))
    }
}
