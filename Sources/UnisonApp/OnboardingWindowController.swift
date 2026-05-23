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
            // Strictly `.borderless` — NO `.fullSizeContentView` and NO
            // `.titled`. `.fullSizeContentView` is for titled windows
            // and is what makes macOS draw a focus ring around the
            // square window rect; a pure borderless window doesn't get
            // a focus ring drawn around its content. Combined with the
            // SwiftUI `.liquidGlass` filling the entire content area,
            // the visible rounded glass card and the window key state
            // line up exactly.
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
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            // Internal title (never rendered because of `.hidden`) so the
            // Tart screenshot harness can locate this window via
            // `process "Unison" → window "Unison Onboarding"` in
            // AppleScript and crop the screencap to its bounds.
            w.title = "Unison Onboarding"
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

            // Wrap the SwiftUI content in an NSVisualEffectView with
            // `.behindWindow` blending so the blur tracks whatever's
            // *behind* the window in real time — desktop wallpaper
            // changes, other apps moving, video playing underneath,
            // etc. SwiftUI's `glassEffect()` modifier on its own
            // renders a static within-window snapshot in many
            // configurations (no NSVisualEffectView ancestor → no
            // way to sample behind-window content). The user noticed:
            // "наш Liquid Glass не динамичен". This wrapping is what
            // actual macOS apps use for live window vibrancy.
            //
            // Rounded mask + window-level transparency keeps the
            // borderless card shape: the visible glass is the
            // rounded `veView`, the corners outside the radius are
            // transparent (window passes through to desktop).
            let host = NSHostingController(rootView: root)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            let veView = NSVisualEffectView()
            veView.material = .windowBackground
            veView.blendingMode = .behindWindow
            veView.state = .active
            veView.wantsLayer = true
            veView.layer?.cornerRadius = OnboardingLayout.windowCornerRadius
            veView.layer?.masksToBounds = true
            veView.translatesAutoresizingMaskIntoConstraints = false
            veView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: veView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: veView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: veView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: veView.trailingAnchor),
            ])
            w.contentView = veView
            window = w
        }
        // Re-probe permissions / installer / keychain on every show
        // so a user who closed the window, granted mic in System
        // Settings, and re-opened sees fresh state. Without this the
        // onboarding card would keep showing "Микрофон — не разрешён"
        // until the user manually clicked the request button again.
        viewModel.refresh()

        window?.center()
        // `LSUIElement=true` (menubar agent) apps do NOT come forward
        // on their own when a window appears. Without explicit
        // activation, the onboarding window ends up behind whatever
        // app the user was in — exactly the wrong UX for the very
        // first surface they see. Activate the app, then bring the
        // window forward unconditionally.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    public func hideIfDone() {
        if viewModel.allDone { window?.orderOut(nil) }
    }
}
