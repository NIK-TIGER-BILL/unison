import AppKit
import SwiftUI
import UnisonUI

/// Hosts the "Как пользоваться" `NSWindow`. Same chromeless-glass
/// `.titled` setup as Settings (see CLAUDE.md).
@MainActor
public final class HelpWindowController {
    private var window: NSWindow?

    public init() {}

    public func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Unison · Как пользоваться"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.minSize = NSSize(width: 560, height: 380)
            w.maxSize = NSSize(width: 800, height: 1000)

            w.contentViewController = GlassHostingViewController(
                rootView: HelpView(),
                style: .regular,
                cornerRadius: 10
            )
            w.setContentSize(NSSize(width: 560, height: 520))
            w.center()
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
