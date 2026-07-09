import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

/// Isolated visual snapshots of `SegmentedToggle` — the Call / Listen
/// mode picker whose selection chip is live Liquid Glass. Rendered
/// larger than it appears in the popover so the chip position, the
/// active/inactive label treatment, and both icons stay legible for
/// regression review.
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

    @Test func segmentedToggle_callSelected() {
        snap(floor(toggle(.call), size: Self.size), size: Self.size)
    }

    @Test func segmentedToggle_listenSelected() {
        snap(floor(toggle(.listen), size: Self.size), size: Self.size)
    }

    /// Reduce Transparency → live glass resolves to `.identity`, so the
    /// chip must fall back to a solid fill rather than collapse to its rim.
    /// `\.accessibilityReduceTransparency` is get-only on this SDK; the
    /// `_`-shadow is the only settable lever (see `LiquidGlassLiveTests`).
    @Test func segmentedToggle_reduceTransparency() {
        let view = toggle(.call).environment(\._accessibilityReduceTransparency, true)
        snap(floor(view, size: Self.size), size: Self.size)
    }

    /// Increase Contrast → the selected chip gains a hairline border and
    /// the inactive label brightens while keeping a gap from the active one.
    @Test func segmentedToggle_increasedContrast() {
        let view = toggle(.call).environment(\._colorSchemeContrast, .increased)
        snap(floor(view, size: Self.size), size: Self.size)
    }

    /// Locked/dimmed — mirrors `PopoverView.modeToggle` while a session is
    /// active (`.disabled(true).opacity(0.55)`).
    @Test func segmentedToggle_disabledDimmed() {
        let view = toggle(.call).disabled(true).opacity(0.55)
        snap(floor(view, size: Self.size), size: Self.size)
    }
}
