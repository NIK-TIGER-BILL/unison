import AppKit
import SwiftUI
import UnisonUI

/// Borderless windows don't accept key/main by default — overriding
/// these lets the API-key text field and the ESC handler work.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the onboarding `NSWindow`. Bridges UnisonUI callbacks
/// (`onCompleted`, `onOpenURL`, `onClose`) into AppKit-level actions.
@MainActor
public final class OnboardingWindowController {
    private var window: NSWindow?
    private let viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
        self.viewModel.onCompleted = { [weak self] in
            self?.window?.orderOut(nil)
        }
        // After a foreign-process system dialog (TCC mic / audio-capture
        // prompt, installer admin-auth) closes, macOS restores the prior
        // regular app — not this `LSUIElement` agent. Re-run the
        // bring-to-front dance so the onboarding window doesn't sink
        // behind other apps' windows.
        self.viewModel.onRequestForeground = { [weak self] in
            self?.bringToFront()
        }
    }

    public func show() {
        if window == nil {
            let w = KeyableBorderlessWindow(
                contentRect: NSRect(x: 200, y: 200, width: 440, height: 620),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Internal title for the Tart screenshot harness.
            w.title = "Unison Onboarding"
            // Borderless card has no titlebar to grab — drag anywhere.
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true
            w.acceptsMouseMovedEvents = true

            let root = OnboardingView(
                vm: viewModel,
                onOpenURL: { url in
                    NSWorkspace.shared.open(url)
                },
                onClose: { [weak w] in
                    w?.orderOut(nil)
                }
            )

            w.contentViewController = GlassHostingViewController(
                rootView: root,
                style: .regular,
                cornerRadius: OnboardingLayout.windowCornerRadius
            )
            window = w
        }
        // Re-probe permissions / installer / keychain on every show
        // so closing the window, granting mic in System Settings, and
        // re-opening picks up the fresh state.
        viewModel.refresh()

        window?.center()
        bringToFront()
    }

    /// Brings the onboarding window to the foreground. `LSUIElement=true`
    /// agents need explicit activation to come forward — otherwise the
    /// window opens (or ends up) behind whatever app the user was in.
    /// Called on first `show()` and re-invoked via `onRequestForeground`
    /// after every foreign system dialog dismisses.
    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

}
