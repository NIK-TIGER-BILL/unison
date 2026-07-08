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

    @Test func tintForwardsToGlass() {
        let v = LiquidGlassContainerView(frame: .zero)
        let c = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.25)
        v.glassTint = c
        let glass = v.subviews.first { $0 is NSGlassEffectView } as? NSGlassEffectView
        #expect(glass?.tintColor == c)
    }
}
