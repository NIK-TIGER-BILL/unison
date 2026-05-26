import AppKit
import SwiftUI
import UnisonUI

/// Hosts the floating, borderless transcript panel. Bottom-centered,
/// 60% of screen width (clamped 520…720pt), rides over all spaces and
/// full-screen apps. Background is transparent; glass lives on each
/// bubble + the control pill (see CLAUDE.md).
@MainActor
public final class TranscriptWindowController {
    private var window: NSWindow?
    private let viewModel: TranscriptViewModel

    /// `nonisolated` so `computeFrame(on:)` can be unit-tested.
    nonisolated static let minWidth: CGFloat = 520
    nonisolated static let maxWidth: CGFloat = 720
    nonisolated static let widthFraction: CGFloat = 0.60
    nonisolated static let panelHeight: CGFloat = 360
    nonisolated static let bottomMargin: CGFloat = 22

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
        // Forward the modal's "Остановить" to the orchestrator. No-op
        // when the VM was constructed without one (tests).
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
            // Drag goes through `WindowDragHandle` inside the pill so
            // sliders in the settings popover keep their own drags.
            panel.isMovableByWindowBackground = false
            panel.hasShadow = false
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            // Don't steal keyboard focus from the meeting client.
            panel.becomesKeyOnlyIfNeeded = true
            // Internal title for the Tart screenshot harness.
            panel.title = "Unison Transcript"

            // `host.view.frame` MUST be set before contentViewController
            // — TranscriptView is `maxWidth/maxHeight: .infinity`, so
            // its `preferredContentSize` is (0,0) and AppKit otherwise
            // collapses the panel to 0×0.
            let host = NSHostingController(rootView: TranscriptView(vm: viewModel))
            host.view.frame = NSRect(origin: .zero, size: frame.size)
            panel.contentViewController = host
            window = panel
        } else {
            // Re-center each show so monitor reconnects don't strand
            // the panel off-screen.
            window?.setFrame(Self.computeFrame(on: NSScreen.main), display: false)
        }
        window?.orderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }

    /// Computed frame for the panel. Public for tests.
    public nonisolated static func computeFrame(on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(maxWidth, max(minWidth, visible.width * widthFraction))
        let x = visible.midX - width / 2
        let y = visible.minY + bottomMargin
        return NSRect(x: x, y: y, width: width, height: panelHeight)
    }
}
