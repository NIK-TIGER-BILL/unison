import AppKit
import SwiftUI
import UnisonUI

/// Borderless NSWindow hosting the `DiagnosticSheet`. Follows the same
/// chromeless-glass pattern as `OnboardingWindowController` so the
/// SwiftUI `.liquidGlass` panel fills the entire window without a
/// double-chrome AppKit titlebar on top.
@MainActor
public final class DiagnosticWindowController {
    private var window: NSWindow?
    private let collector: DiagnosticCollector

    public init(collector: DiagnosticCollector) {
        self.collector = collector
    }

    public func show() {
        let info = collector.collect()
        if window == nil {
            // 640pt rect lets the 600pt-wide sheet sit centered with a
            // small breathing margin around its own glass border.
            let w = KeyableBorderlessDiagWindow(
                contentRect: NSRect(x: 200, y: 200, width: 640, height: 640),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Unison Diagnostics"
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true
            w.acceptsMouseMovedEvents = true
            window = w
        }
        let root = DiagnosticSheet(
            info: info,
            onCopy: { [weak self] in
                guard let self else { return }
                self.copyToClipboard(info: info)
            },
            onClose: { [weak self] in
                self?.window?.orderOut(nil)
            }
        )
        window?.contentViewController = NSHostingController(rootView: root)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func copyToClipboard(info: DiagnosticInfo) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(info.asPlainText, forType: .string)
    }
}

/// Borderless NSWindow that still accepts keyboard focus. Cmd+W and Esc
/// dismiss it via the SwiftUI `keyboardShortcut` on the Close button.
private final class KeyableBorderlessDiagWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
