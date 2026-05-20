import AppKit
import SwiftUI
import UnisonUI

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
            let w = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 440, height: 620),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = ""
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.backgroundColor = .clear
            w.isOpaque = false

            // Hide the default traffic lights — the design ships its
            // own close button inside the header.
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true

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
