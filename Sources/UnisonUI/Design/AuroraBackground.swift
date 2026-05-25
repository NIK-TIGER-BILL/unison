import SwiftUI

/// Aurora gradient background. DESIGN.md §1.1.
///
/// **Production policy**: do NOT place this behind any of the app's
/// real windows. The actual NSWindows are transparent so Apple's
/// Liquid Glass material refracts the live desktop wallpaper. Painting
/// our own gradient underneath blocks that refraction and creates a
/// visible "window in window" effect.
///
/// **Where this still lives**: snapshot tests render in an offscreen
/// `NSHostingView` with no real desktop behind the glass — stacking on
/// top of `Color.black` (current default) or this aurora produces a
/// readable backdrop for visual diffing. SwiftUI previews can also opt
/// in for the same reason.
///
/// Layers (back → front):
/// 1. Vertical linear gradient `#0a0820 → #100c2e → #1a1142`
/// 2. Cyan radial highlight, top-right (`rgba(100,230,255,0.45)`)
/// 3. Magenta radial highlight, bottom-left (`rgba(255,110,200,0.40)`)
/// 4. Lavender radial highlight, bottom-centre (`rgba(150,100,255,0.30)`)
///
/// Coordinates of the radial centres and approximate "ellipse" sizing
/// are reproduced via `UnitPoint` and width/height fractions; SwiftUI's
/// `RadialGradient` is circular, so each ellipse is faked with a tightly
/// scaled wrapper.
public struct AuroraBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            // 1. Floor — vertical purple gradient.
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0x0a / 255, green: 0x08 / 255, blue: 0x20 / 255), location: 0.0),
                    .init(color: Color(red: 0x10 / 255, green: 0x0c / 255, blue: 0x2e / 255), location: 0.5),
                    .init(color: Color(red: 0x1a / 255, green: 0x11 / 255, blue: 0x42 / 255), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // 2-4. Three aurora highlights.
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                ZStack {
                    // Cyan top-right (80%, 30%)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 100 / 255, green: 230 / 255, blue: 255 / 255).opacity(0.45),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: max(w, h) * 0.45
                            )
                        )
                        .frame(width: w * 1.2, height: h)
                        .position(x: w * 0.8, y: h * 0.3)

                    // Magenta bottom-left (25%, 70%)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 255 / 255, green: 110 / 255, blue: 200 / 255).opacity(0.40),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: max(w, h) * 0.55
                            )
                        )
                        .frame(width: w * 1.4, height: h * 1.2)
                        .position(x: w * 0.25, y: h * 0.7)

                    // Lavender bottom-centre (60%, 90%)
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color(red: 150 / 255, green: 100 / 255, blue: 255 / 255).opacity(0.30),
                                    .clear,
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: max(w, h) * 0.4
                            )
                        )
                        .frame(width: w, height: h * 0.8)
                        .position(x: w * 0.6, y: h * 0.9)
                }
                .blendMode(.normal)
            }
        }
        .ignoresSafeArea()
    }
}

public extension View {
    /// Place this view on top of the Aurora gradient background. Common
    /// for onboarding and settings windows.
    func auroraBackground() -> some View {
        ZStack {
            AuroraBackground()
            self
        }
    }
}
