import AppKit
import SwiftUI
import UnisonUI

/// Hosts the floating, borderless transcript panel.
///
/// Layout per plan §5.2:
/// - `styleMask: [.borderless, .nonactivatingPanel]` — no system title bar;
///   non-activating so clicks don't steal focus from the underlying app
///   (e.g. Zoom).
/// - `level = .floating`, `collectionBehavior = [.canJoinAllSpaces,
///   .stationary]` so the panel rides over all spaces and full-screen apps.
/// - Width = 60% of the main screen, clamped to `520 ... 720pt`; height is
///   a generous floor so the SwiftUI bubble stack has room to expand.
///   Positioned 22pt above the visible bottom edge, horizontally centered.
/// - Transparent background so the SwiftUI glass material is the only
///   visible chrome.
/// - `isMovableByWindowBackground = true` — the SwiftUI content is mostly
///   transparent (only the pill and bubbles have any hit-testable surface),
///   so dragging anywhere on the pill or background moves the panel.
@MainActor
public final class TranscriptWindowController {
    private var window: NSWindow?
    private let viewModel: TranscriptViewModel

    /// Minimum / maximum width of the transcript zone. The HTML mock uses
    /// `width: 60%; min-width: 520px; max-width: 720px;`. Declared
    /// `nonisolated` so the pure `computeFrame(on:)` helper can be tested
    /// off the main actor.
    nonisolated static let minWidth: CGFloat = 520
    nonisolated static let maxWidth: CGFloat = 720
    nonisolated static let widthFraction: CGFloat = 0.60
    /// Floor for the panel height — leaves room for ≈3 large bubble groups
    /// plus the pill above the screen bottom margin.
    nonisolated static let panelHeight: CGFloat = 360
    nonisolated static let bottomMargin: CGFloat = 22

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
        // Route the modal's "Остановить" action through the orchestrator so
        // confirming the dialog actually stops translation. Falls back to a
        // no-op when the VM was constructed without an orchestrator (tests).
        let orch = viewModel.orchestrator
        self.viewModel.onStopRequested = {
            guard let orch else { return }
            Task { @MainActor in await orch.stop() }
        }
    }

    public func show() {
        if window == nil {
            let frame = Self.computeFrame(on: NSScreen.main)
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.hasShadow = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // Non-activating: clicking the panel doesn't steal focus from
            // the meeting client, but views still receive mouse events.
            panel.becomesKeyOnlyIfNeeded = true

            let host = NSHostingController(rootView: TranscriptView(vm: viewModel))
            host.view.frame = NSRect(origin: .zero, size: frame.size)
            panel.contentViewController = host
            window = panel
        } else {
            // Re-center on the current main screen each time we show so
            // monitor reconnects don't strand the panel off-screen.
            window?.setFrame(Self.computeFrame(on: NSScreen.main), display: false)
        }
        window?.orderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    /// Compute the panel's screen frame. Public for tests.
    public nonisolated static func computeFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(maxWidth, max(minWidth, visible.width * widthFraction))
        let x = visible.midX - width / 2
        let y = visible.minY + bottomMargin
        return NSRect(x: x, y: y, width: width, height: panelHeight)
    }
}
