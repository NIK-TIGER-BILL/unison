import AppKit
import SwiftUI
import UnisonUI

/// Borderless NSWindow that still accepts keyboard focus. Needed
/// because the onboarding window is chromeless (no titlebar, no
/// traffic lights) but must still react to ESC and capture text input
/// in the API-key field.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosts the onboarding `NSWindow`. UnisonUI cannot reach AppKit, so
/// this controller bridges:
/// - `vm.onCompleted` → close the window when all three steps finish.
/// - `onOpenURL` → `NSWorkspace.shared.open(_:)` for the System Settings
///   deep link and the OpenAI keys page.
/// - `onClose` → window close (used by the title-bar X button, ESC, and
///   the "Готово" footer button).
@MainActor
public final class OnboardingWindowController {
    private var window: NSWindow?
    private let viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
        // Auto-close once every prerequisite is satisfied.
        self.viewModel.onCompleted = { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    public func show() {
        if window == nil {
            // Borderless + transparent so Apple's Liquid Glass (applied
            // by the SwiftUI panel via `.liquidGlass(cornerRadius:)`)
            // can refract the real desktop wallpaper through the host
            // NSWindow. The design ships a close button inside the
            // header — there's no macOS-drawn titlebar to dismiss.
            //
            // Critical for the macOS 26 glass to work correctly:
            // - `isOpaque = false` + `backgroundColor = .clear` lets the
            //   compositor see through the window to the desktop.
            // - `hasShadow = true` keeps the floating-card depth that
            //   real macOS 26 windows have (drawn by the compositor,
            //   not by SwiftUI).
            // - `isMovableByWindowBackground = true` so the user can
            //   drag the glass card from anywhere on its surface — a
            //   borderless window has no titlebar to grab.
            let w = KeyableBorderlessWindow(
                contentRect: NSRect(x: 200, y: 200, width: 440, height: 620),
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true // System compositor draws the glass-card shadow.
            // Borderless windows need explicit hints to accept key/main.
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
            w.contentViewController = NSHostingController(rootView: root)
            window = w
        }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    public func hideIfDone() {
        if viewModel.allDone { window?.orderOut(nil) }
    }
}
