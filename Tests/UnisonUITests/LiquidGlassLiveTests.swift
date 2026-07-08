import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import UnisonUI

@MainActor
struct LiquidGlassLiveTests {

    @Test func containerHostsGlassAndIsHitTestTransparent() {
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        // Хостит ровно один NSGlassEffectView.
        #expect(v.subviews.contains { $0 is NSGlassEffectView })
        // Чистая декорация — никогда не перехватывает указатель.
        #expect(v.hitTest(NSPoint(x: 10, y: 10)) == nil)
    }

    @Test func glassFillsBoundsAfterLayout() {
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 120, height: 50))
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        let glass = v.subviews.first { $0 is NSGlassEffectView }
        #expect(glass?.frame == v.bounds)
    }

    @Test func maskTracksShapePath() {
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        v.pathProvider = { RoundedRectangle(cornerRadius: 18, style: .continuous).path(in: $0).cgPath }
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        let mask = v.layer?.mask as? CAShapeLayer
        #expect(mask != nil)
        // Путь покрывает прямоугольник вью (flip по Y сохраняет bbox).
        let bbox = mask?.path?.boundingBoxOfPath ?? .zero
        #expect(abs(bbox.width - 200) < 1.0)
        #expect(abs(bbox.height - 60) < 1.0)
    }

    @Test func maskUsesBackingScaleForCrispCorners() {
        // No window in the test → falls back to 2.0 so an offscreen mask
        // isn't rasterized at 1x (which would soften the clipped corners).
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: 100, height: 40))
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        let mask = v.layer?.mask as? CAShapeLayer
        #expect(mask?.contentsScale == 2.0)
    }

    @Test func maskFlipsAsymmetricShapeToCorrectEdge() {
        // UnevenRoundedRectangle carved ONLY at the SwiftUI top-leading
        // corner. SwiftUI is top-left/y-down; the CALayer mask is
        // bottom-left/y-up and the container Y-flips (y -> height - y).
        // So in LAYER space the carved corner must land at the TOP
        // (large y), and the square bottom-leading corner at the BOTTOM
        // (small y). An inverted/removed flip fails this.
        let w: CGFloat = 200
        let h: CGFloat = 100
        let v = LiquidGlassContainerView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        v.pathProvider = {
            UnevenRoundedRectangle(
                topLeadingRadius: 40, bottomLeadingRadius: 0,
                bottomTrailingRadius: 0, topTrailingRadius: 0,
                style: .continuous
            ).path(in: $0).cgPath
        }
        v.needsLayout = true
        v.layoutSubtreeIfNeeded()
        let path = (v.layer?.mask as? CAShapeLayer)?.path
        #expect(path != nil)
        // Layer space (y-up). Near-top-leading is carved (outside); its
        // vertical mirror near-bottom-leading is square (inside).
        #expect(path?.contains(CGPoint(x: 4, y: h - 4)) == false) // top: carved
        #expect(path?.contains(CGPoint(x: 4, y: 4)) == true)      // bottom: solid
    }

    @Test func tintForwardsToGlass() {
        let v = LiquidGlassContainerView(frame: .zero)
        let c = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.25)
        v.glassTint = c
        let glass = v.subviews.first { $0 is NSGlassEffectView } as? NSGlassEffectView
        #expect(glass?.tintColor == c)
    }

    // MARK: - A11y branch coverage (Reduce Transparency fallback)
    //
    // `LiquidGlassLivePanel.body` delegates to the static `.liquidGlass`
    // (pure SwiftUI `.glassEffect`, no AppKit representable) under
    // `accessibilityReduceTransparency`, and to the live `LiquidGlassLive`
    // (which hosts a `LiquidGlassContainerView`) otherwise. Walk the
    // AppKit tree for that unambiguous marker type instead of asserting
    // on pixels.

    @Test func normalModeInstantiatesLiveGlass() {
        // `\.accessibilityReduceTransparency` is get-only on this SDK
        // (SwiftUICore); the get/set shadow `_accessibilityReduceTransparency`
        // is what actually backs it and is the only lever available to
        // drive this branch from a test. See reduceTransparencyFallsBackToStaticGlass.
        let view = Color.clear.frame(width: 100, height: 40)
            .liquidGlassLive(cornerRadius: 14)
            .environment(\._accessibilityReduceTransparency, false)
        #expect(hostsLiveGlassContainer(view, size: CGSize(width: 100, height: 40)))
    }

    @Test func reduceTransparencyFallsBackToStaticGlass() {
        let view = Color.clear.frame(width: 100, height: 40)
            .liquidGlassLive(cornerRadius: 14)
            .environment(\._accessibilityReduceTransparency, true)
        #expect(!hostsLiveGlassContainer(view, size: CGSize(width: 100, height: 40)))
    }
}

/// Recursively true if any descendant view is a `LiquidGlassContainerView`.
/// Hosts `view` in an offscreen borderless window (same pattern as
/// `renderToPNG` in SnapshotConfig.swift) so `NSViewRepresentable`
/// actually materializes its backing `NSView`, then walks the AppKit
/// subview tree for our own container type — present only on the live
/// glass path, never on the static `.glassEffect` path.
@MainActor
private func hostsLiveGlassContainer<V: View>(_ view: V, size: CGSize) -> Bool {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(
        contentRect: host.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = false
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    func walk(_ v: NSView) -> Bool {
        if v is LiquidGlassContainerView { return true }
        return v.subviews.contains(where: walk)
    }
    return walk(host)
}
