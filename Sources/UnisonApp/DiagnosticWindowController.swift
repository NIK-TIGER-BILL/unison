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
        // Same NSVisualEffectView wrap as OnboardingWindowController:
        // SwiftUI `glassEffect()` alone doesn't give us *behind-window*
        // live vibrancy, so wrap in an explicit NSVisualEffectView
        // with rounded mask. See OnboardingWindowController for the
        // detailed rationale.
        let host = NSHostingController(rootView: root)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        let veView = NSVisualEffectView()
        // `.hudWindow` is the canonical Liquid Glass material on
        // macOS Tahoe (used by Notification Center / Spotlight /
        // Control Center). `.windowBackground` looks like solid panel
        // on Tahoe and gives the "no liquid glass" appearance.
        veView.material = .hudWindow
        veView.blendingMode = .behindWindow
        veView.state = .active
        veView.wantsLayer = true
        veView.layer?.cornerRadius = 18
        veView.layer?.masksToBounds = true
        veView.translatesAutoresizingMaskIntoConstraints = false
        veView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: veView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: veView.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: veView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: veView.trailingAnchor),
        ])
        window?.contentView = veView
        window?.contentViewController = nil
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
