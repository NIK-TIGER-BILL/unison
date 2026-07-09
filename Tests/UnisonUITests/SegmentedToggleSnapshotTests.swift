import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

/// Isolated snapshots of `SegmentedToggle` — the Call / Listen mode
/// picker whose selection chip is live Liquid Glass, rendered larger
/// than it appears in the popover.
///
/// The chip is a live `NSGlassEffectView`, whose offscreen capture is
/// non-deterministic across GPU / compositor state (local vs CI) — the
/// caveat `SnapshotConfig` and `TranscriptViewSnapshotTests` call out.
/// In the popover it's ~3% of the frame, so the 0.91-precision popover
/// references absorb it; rendered in isolation it dominates and flakes.
/// So the live-glass states here are `snapSmoke` (render-only: builds,
/// lays out at the right size, doesn't crash). The one pixel-compared
/// case is `reduceTransparency`, where the glass resolves to a
/// deterministic solid fallback fill — that guards the chip position,
/// the labels, and the Reduce-Transparency fallback itself. The
/// live-glass appearance is verified by hand in the VM.
@MainActor
struct SegmentedToggleSnapshotTests {

    /// Menu-bar glass multiplies against a system-blur backdrop; here we
    /// approximate that with opaque black so the material has something
    /// to composite over (matches `PopoverViewSnapshotTests`).
    private func floor<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view.padding(.horizontal, 16)
        }
        .frame(width: size.width, height: size.height)
    }

    private static let size = CGSize(width: 320, height: 64)

    private func toggle(_ mode: SessionMode) -> some View {
        SegmentedToggle(
            selection: .constant(mode),
            segments: [
                .init(id: "call", title: "Call", icon: Image(systemName: "phone.fill"), mode: .call),
                .init(id: "listen", title: "Listen", icon: Image(systemName: "headphones"), mode: .listen)
            ]
        )
    }

    // Live-glass states — render-only (see type comment): they exercise
    // both matched-geometry positions, Increase Contrast, and the
    // dimmed/locked look without asserting exact pixels.
    @Test func segmentedToggle_callSelected() {
        snapSmoke(floor(toggle(.call), size: Self.size), size: Self.size)
    }

    @Test func segmentedToggle_listenSelected() {
        snapSmoke(floor(toggle(.listen), size: Self.size), size: Self.size)
    }

    @Test func segmentedToggle_increasedContrast() {
        let view = toggle(.call).environment(\._colorSchemeContrast, .increased)
        snapSmoke(floor(view, size: Self.size), size: Self.size)
    }

    @Test func segmentedToggle_disabledDimmed() {
        let view = toggle(.call).disabled(true).opacity(0.55)
        snapSmoke(floor(view, size: Self.size), size: Self.size)
    }

    /// Reduce Transparency → live glass resolves to `.identity`, so the
    /// chip falls back to a solid fill (not a bare rim). No live
    /// `NSGlassEffectView` is involved, so the render is deterministic —
    /// this one is pixel-compared and doubles as the chip-position /
    /// label guard. `\.accessibilityReduceTransparency` is get-only on
    /// this SDK; the `_`-shadow is the only settable lever (see
    /// `LiquidGlassLiveTests`).
    @Test func segmentedToggle_reduceTransparency() {
        let view = toggle(.call).environment(\._accessibilityReduceTransparency, true)
        snap(floor(view, size: Self.size), size: Self.size)
    }
}
