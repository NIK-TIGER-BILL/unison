import SwiftUI
import Testing
@testable import UnisonUI

/// Visual snapshots of the canonical Unison logo. Compares against
/// `design/logo-final/index.html` (`<symbol id="logo-unison">` and
/// `<symbol id="logo-unison-paused">`).
@MainActor
struct LogoShapeSnapshotTests {

    private func render(_ shape: UnisonLogoShape, size: CGSize) -> some View {
        ZStack {
            Color.black
            shape
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round)
                )
                .padding(24)
        }
        .frame(width: size.width, height: size.height)
    }

    @Test func logo_full() throws {
        snap(render(UnisonLogoShape(showVoiceStreams: true), size: SnapSize.logo), size: SnapSize.logo)
    }

    @Test func logo_paused() throws {
        snap(render(UnisonLogoShape(showVoiceStreams: false), size: SnapSize.logo), size: SnapSize.logo)
    }
}
