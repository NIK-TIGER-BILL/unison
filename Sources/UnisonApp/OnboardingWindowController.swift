import AppKit
import SwiftUI
import UnisonUI

@MainActor
public final class OnboardingWindowController {
    private var window: NSWindow?
    private let viewModel: OnboardingViewModel

    public init(viewModel: OnboardingViewModel) {
        self.viewModel = viewModel
    }

    public func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 200, y: 200, width: 460, height: 360),
                styleMask: [.titled, .closable], backing: .buffered, defer: false
            )
            w.title = "Unison"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: OnboardingView(vm: viewModel))
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
    }

    public func hideIfDone() {
        if viewModel.allDone { window?.orderOut(nil) }
    }
}
