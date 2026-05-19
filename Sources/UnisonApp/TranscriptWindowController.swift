import AppKit
import SwiftUI
import UnisonUI

@MainActor
public final class TranscriptWindowController {
    private var window: NSWindow?
    private let viewModel: TranscriptViewModel

    public init(viewModel: TranscriptViewModel) {
        self.viewModel = viewModel
    }

    public func show() {
        if window == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 100, y: 100, width: 400, height: 480),
                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.level = .floating
            panel.isMovableByWindowBackground = true
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.contentViewController = NSHostingController(rootView: TranscriptView(vm: viewModel))
            window = panel
        }
        window?.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        window?.orderOut(nil)
    }
}
