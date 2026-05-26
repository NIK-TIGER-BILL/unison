import SwiftUI

/// Canonical SwiftUI wrapper around macOS 26's `glassEffect(_:in:)`.
/// Every SwiftUI glass surface in the app routes through here, so the
/// `\.accessibilityReduceTransparency` (→ `.identity`) and
/// `\.colorSchemeContrast` (→ optional 1.5pt hairline) handling lives
/// in one place. See CLAUDE.md for the AppKit counterpart.
struct LiquidGlassPanel<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let interactive: Bool
    let highContrastHairline: Bool

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    init(
        shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        highContrastHairline: Bool = true
    ) {
        self.shape = shape
        self.tint = tint
        self.interactive = interactive
        self.highContrastHairline = highContrastHairline
    }

    func body(content: Content) -> some View {
        content
            .glassEffect(resolvedGlass, in: shape)
            .overlay {
                if highContrastHairline && contrast == .increased {
                    shape
                        .strokeBorder(UnisonColors.whiteAlpha(0.30), lineWidth: 1.5)
                }
            }
    }

    private var resolvedGlass: Glass {
        if reduceTransparency { return .identity }
        var g: Glass = .regular
        if let tint { g = g.tint(tint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Wrap the view in Liquid Glass with a custom shape.
    /// - Parameters:
    ///   - tint: Keep opacities ≤ 0.30 so the system's refraction
    ///     still picks up the wallpaper underneath.
    ///   - highContrastHairline: set `false` when the caller renders
    ///     its own border (Bubble, PrimaryGlassButton).
    func liquidGlass<S: InsettableShape>(
        shape: S,
        tint: Color? = nil,
        interactive: Bool = false,
        highContrastHairline: Bool = true
    ) -> some View {
        modifier(LiquidGlassPanel(
            shape: shape,
            tint: tint,
            interactive: interactive,
            highContrastHairline: highContrastHairline
        ))
    }

    /// Rounded-rectangle convenience.
    func liquidGlass(
        cornerRadius: CGFloat = 14,
        tint: Color? = nil,
        interactive: Bool = false,
        highContrastHairline: Bool = true
    ) -> some View {
        liquidGlass(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            interactive: interactive,
            highContrastHairline: highContrastHairline
        )
    }
}
