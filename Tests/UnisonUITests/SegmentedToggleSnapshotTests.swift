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
}
