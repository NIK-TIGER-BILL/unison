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
            // Borderless + transparent so the SwiftUI panel (which has
            // its own rounded corners, shadow, and Aurora background)
            // is the only chrome the user sees. The design ships a
            // close button inside the header — there's no macOS-drawn
            // titlebar to dismiss.
            let w = KeyableBorderlessWindow(
                contentRect: NSRect(x: 200, y: 200, width: 440, height: 620),
                styleMask: [.borderless, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false // SwiftUI panel already paints a shadow.
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
