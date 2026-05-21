import SwiftUI

/// Apply Apple's native Liquid Glass material to a view.
///
/// Thin wrapper around the macOS 26 `glassEffect(_:in:)` modifier so
/// existing call sites (`.liquidGlass(cornerRadius:)`) don't change.
/// The system handles every aspect of the Liquid Glass look — specular
/// highlight, conic rim, displacement, shadowing — and the result
/// matches the macOS Tahoe aesthetic automatically.
///
/// Respects `\.accessibilityReduceTransparency`: when on, we hand the
/// system `.identity` glass (effectively flat) so motion-sensitive
/// users get a clean, opaque surface.
///
/// Respects `\.colorSchemeContrast`: when Increase Contrast is on, the
/// modifier draws a stronger hairline border on top of the system
/// glass so panel edges remain visible against busy backgrounds.
///
/// Usage:
/// ```swift
/// VStack { … }
///     .liquidGlass(cornerRadius: 14)
/// ```
public struct LiquidGlassPanel: ViewModifier {
    public let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isHighContrast = contrast == .increased
        return content
            .glassEffect(
                reduceTransparency ? .identity : .regular,
                in: shape
            )
            .overlay {
                if isHighContrast {
                    shape
                        .strokeBorder(UnisonColors.whiteAlpha(0.30), lineWidth: 1.5)
                }
            }
    }
}

public extension View {
    /// Wrap this view in Apple's native Liquid Glass material.
    /// - Parameter cornerRadius: 22–26 for main panels (popover/window),
    ///   12–14 for inner blocks per DESIGN.md §4.2.
    func liquidGlass(cornerRadius: CGFloat = 14) -> some View {
        modifier(LiquidGlassPanel(cornerRadius: cornerRadius))
    }
}
