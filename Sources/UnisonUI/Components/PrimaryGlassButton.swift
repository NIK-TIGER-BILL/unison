import SwiftUI

/// Full-width primary action button. Native Liquid Glass on macOS 26.
///
/// The visual is hand-built rather than `buttonStyle(.glassProminent)`
/// because the latter, on a dark popover and without a `.tint`, renders
/// as a near-opaque dark fill — flat, low-contrast, the opposite of the
/// raised translucent-white surface the design specifies
/// (`design/popover-final/index.html` §`.start-btn`):
/// ```
/// background: linear-gradient(180deg, rgba(255,255,255,0.22),
///                                     rgba(255,255,255,0.08));
/// border: 0.5px solid rgba(255,255,255,0.22);
/// inset 0 1px 0 rgba(255,255,255,0.28)  /* top specular */
/// 0 4px 12px rgba(0,0,0,0.28)            /* drop shadow */
/// ```
///
/// We get that look by:
/// 1. `.glassEffect(.regular.interactive(), in: …)` — system Liquid
///    Glass surface, so the button still refracts/responds to hover and
///    press the same way `.glassProminent` does.
/// 2. A white linear-gradient overlay (0.22 → 0.08) that gives the
///    button the actual visible colour. Without this the glass is
///    nearly transparent against the dark popover and the button reads
///    as flat black.
/// 3. A hairline white stroke + inset specular highlight, both
///    blendMode `.plusLighter` so they pop on dark backgrounds without
///    over-saturating on light ones.
/// 4. A subtle drop shadow for elevation.
///
/// Two variants:
/// - `.standard` — neutral white-glass (Start translating, Done).
/// - `.destructive` — coral-tinted (Stop translating); same recipe but
///   the gradient and stroke shift to Liquid-Glass-Red.
public struct PrimaryGlassButton: View {
    public enum Variant: Equatable, Sendable {
        case standard
        case destructive
    }

    public let title: String
    public let icon: Image?
    public let variant: Variant
    public let isLoading: Bool
    public let action: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        title: String,
        icon: Image? = nil,
        variant: Variant = .standard,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    Spinner(size: 12, lineWidth: 1.5)
                } else if let icon = icon {
                    icon
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(.white)
            .shadow(color: Color.black.opacity(0.25), radius: 0, x: 0, y: 1)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                ZStack {
                    // System Liquid Glass material so the button still
                    // refracts the popover background and reacts to
                    // hover/press the same way `.buttonStyle(.glass)` would.
                    shape
                        .fill(.clear)
                        .glassEffect(
                            reduceTransparency ? .identity : .regular.interactive(),
                            in: shape
                        )
                    // Tint gradient — this is what actually gives the
                    // button its visible colour. White for standard
                    // (rgba 0.22→0.08), coral for destructive.
                    shape
                        .fill(tintGradient)
                    // Hairline rim. `.plusLighter` keeps it visible on
                    // the dark popover material without going neon on
                    // light backgrounds.
                    shape
                        .strokeBorder(borderColor, lineWidth: 0.5)
                        .blendMode(.plusLighter)
                    // Inset top specular — matches the CSS
                    // `inset 0 1px 0 rgba(255,255,255,0.28)` highlight
                    // that sells the raised glass look.
                    shape
                        .inset(by: 0.5)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.0),
                                ],
                                startPoint: .top,
                                endPoint: .center
                            ),
                            lineWidth: 1
                        )
                        .blendMode(.plusLighter)
                }
            )
            .clipShape(shape)
            .shadow(color: shadowColor, radius: 6, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .contentShape(shape)
        .disabled(isLoading)
    }

    /// Gradient that paints the button. Mirrors the CSS:
    /// `linear-gradient(180deg, rgba(255,255,255,0.22), rgba(255,255,255,0.08))`
    /// for the neutral primary, and the coral
    /// `rgba(255,110,130,0.42) → rgba(220,60,90,0.28)` for destructive.
    private var tintGradient: LinearGradient {
        switch variant {
        case .standard:
            LinearGradient(
                colors: [
                    Color.white.opacity(0.22),
                    Color.white.opacity(0.08),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .destructive:
            LinearGradient(
                colors: [
                    Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255).opacity(0.42),
                    Color(red: 220 / 255, green:  60 / 255, blue:  90 / 255).opacity(0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    /// 0.5pt rim. White on standard, coral on destructive — matches the
    /// CSS `border: 0.5px solid rgba(255,255,255,0.22)` (or the coral
    /// equivalent inside `.popover.translating`).
    private var borderColor: Color {
        switch variant {
        case .standard:
            Color.white.opacity(0.22)
        case .destructive:
            Color(red: 255 / 255, green: 110 / 255, blue: 130 / 255).opacity(0.40)
        }
    }

    /// Drop shadow under the button. Neutral black for the standard
    /// variant; warmer red shadow under the destructive variant per
    /// the design (`0 4px 14px rgba(220,60,90,0.32)`).
    private var shadowColor: Color {
        switch variant {
        case .standard:
            Color.black.opacity(0.28)
        case .destructive:
            Color(red: 220 / 255, green: 60 / 255, blue: 90 / 255).opacity(0.32)
        }
    }
}
