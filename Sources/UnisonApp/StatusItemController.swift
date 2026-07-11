import AppKit
import SwiftUI
import UnisonUI

/// Owns the menubar `NSStatusItem`. Left click toggles a custom
/// `MenubarPanel` hosting `PopoverView`; right-click / Control-click
/// opens a context `NSMenu`. See CLAUDE.md for the popover machinery
/// (auto-dismiss debounce, harness mode, why not `NSPopover`).
///
/// `AppDelegate` observes the orchestrator's `SessionState` and pushes
/// a `MenubarState` here on every change.
@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popoverPanel: MenubarPanel
    // Implicitly-unwrapped: it's built from `PopoverView`, whose closures
    // capture `self`, so it can only be assigned after those closures exist —
    // a plain `let` would read as "used before initialized" at capture time.
    private var popoverHost: NSHostingController<PopoverView>!
    private let popoverVM: PopoverViewModel
    /// Timestamp of the most recent `resignKey` dismissal. See the
    /// debounce in `togglePopover`.
    private var lastDismissAt: Date?
    private static let dismissDebounce: TimeInterval = 0.2
    /// Block-observer token for `NSWindow.didResizeNotification` —
    /// kept so `deinit` can unregister it.
    private var resizeObserverToken: (any NSObjectProtocol)?

    public var onStartStop: (() -> Void)?
    public var onShowTranscript: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onShowDiagnostic: (() -> Void)?
    public var onShowHistory: (() -> Void)?
    public var onShowAbout: (() -> Void)?
    public var onQuit: (() -> Void)?

    public var state: MenubarState = .idle {
        didSet {
            guard state != oldValue else { return }
            applyState()
        }
    }

    /// Show / hide the menubar icon. Backs the «Скрывать меню при
    /// старте сессии» behaviour toggle — while hidden, control stays
    /// available via the global hotkeys and the transcript pill.
    public func setStatusItemVisible(_ visible: Bool) {
        statusItem.isVisible = visible
        // A hidden status item can't anchor the popover; close it so it
        // doesn't float orphaned over the desktop.
        if !visible, popoverPanel.isVisible {
            popoverPanel.orderOut(nil)
        }
    }

    public init(
        popoverVM: PopoverViewModel,
        onOpenSettings: @escaping () -> Void = {},
        onStartStop: @escaping () -> Void = {},
        onShowTranscript: @escaping () -> Void = {},
        onShowDiagnostic: @escaping () -> Void = {},
        onShowHistory: @escaping () -> Void = {},
        onShowAbout: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = { Task { @MainActor in NSApp.terminate(nil) } }
    ) {
        self.popoverVM = popoverVM
        self.onOpenSettings = onOpenSettings
        self.onStartStop = onStartStop
        self.onShowTranscript = onShowTranscript
        self.onShowDiagnostic = onShowDiagnostic
        self.onShowHistory = onShowHistory
        self.onShowAbout = onShowAbout
        self.onQuit = onQuit

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let panel = MenubarPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 320),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .vibrantDark)
        // Stable internal title for the Tart screenshot harness's
        // AppleScript window lookup.
        panel.title = "Unison Popover"

        // Assign before creating the SwiftUI host so the closures
        // below can safely capture `self` — otherwise Swift complains
        // that `self.popoverPanel` is used before initialization.
        self.popoverPanel = panel

        let host = NSHostingController(
            rootView: PopoverView(
                vm: popoverVM,
                onOpenSettings: { [weak self] in
                    self?.popoverPanel.orderOut(nil)
                    self?.onOpenSettings?()
                },
                onShowDiagnostic: { [weak self] in
                    self?.popoverPanel.orderOut(nil)
                    self?.onShowDiagnostic?()
                },
                onContentHeightChange: { [weak self] height in
                    // onGeometryChange fires during SwiftUI's main-thread
                    // update; assumeIsolated to reach the @MainActor resize
                    // (same pattern as the didResize observer below).
                    MainActor.assumeIsolated {
                        self?.resizePanelToContentHeight(height)
                    }
                }
            )
        )
        // CRASH FIX (macOS 26.5.1): the SwiftUI card must NOT be the window's
        // size-driving content view.
        //
        // As an `NSHostingController` set directly as `contentViewController`,
        // NSHostingView owns the window size and *animates* every resize
        // (`windowDidLayout` → `updateAnimatedWindowSize` →
        // `NSAnimationContext.runAnimationGroup`). Whenever the popover's height
        // changes while it's visible, that animated resize re-resolves the
        // card's SwiftUI Liquid Glass on every animation frame and faults with
        // EXC_BAD_ACCESS inside Apple's private DesignLibrary
        // (`MaterialProviderBox.resolveLayers`). It's reliably hit by pressing
        // TEST (adds the timer/status rows) and, worse, by a Bluetooth HFP route
        // flapping the "route degraded" row on and off. Removing
        // `.preferredContentSize` isn't enough — NSHostingView still drives the
        // window whenever it's the content view.
        //
        // So we host the card as a *child* controller whose view is a plain
        // `autoresizingMask` subview of a container, and make a plain
        // `NSViewController` (which publishes no `preferredContentSize`) the
        // window's content VC. NSHostingView then never drives/animates the
        // window, so no mid-animation glass re-resolve can happen. We size the
        // panel ourselves, non-animated (`onContentHeightChange` →
        // `resizePanelToContentHeight`); `.intrinsicContentSize` keeps
        // `host.view.fittingSize` reporting the card's ideal size for the open.
        // (Same containment shape as `GlassHostingViewController`.)
        host.sizingOptions = [.intrinsicContentSize]
        self.popoverHost = host
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 320))
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .height]
        container.addSubview(host.view)
        // Layer-clip the container to the SwiftUI `.liquidGlass(cornerRadius: 24)`
        // silhouette so the `hasShadow` doesn't leak into the corners.
        container.wantsLayer = true
        container.layer?.cornerRadius = 24
        container.layer?.masksToBounds = true
        let containerVC = NSViewController()
        containerVC.view = container
        containerVC.addChild(host)
        panel.contentViewController = containerVC

        panel.onResignKey = { [weak self] in
            self?.lastDismissAt = Date()
        }

        // Re-anchor the panel under the menubar icon when SwiftUI
        // content height changes — otherwise it grows from its
        // bottom-left and its top slides up into the menu bar.
        resizeObserverToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.popoverPanel.isVisible else { return }
                self.repositionPanelBelowStatusItem()
            }
        }

        if let button = statusItem.button {
            // Both events so the same handler can branch between popover
            // (left) and context menu (right-click / Control-click).
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleClick(_:))
            button.target = self
            button.image = MenubarIcons.image(for: state)
            button.imagePosition = .imageOnly
            button.toolTip = "Unison"
        }
    }

    deinit {
        if let token = resizeObserverToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Tart-harness entry point (`UNISON_FORCE_STATE=popover-open`).
    /// `forceVisible` suppresses the auto-dismiss path so the
    /// SSH-driven `screencapture` step doesn't race with `resignKey`.
    public func showPopover() {
        guard let button = statusItem.button else { return }
        if popoverPanel.isVisible { return }
        popoverPanel.forceVisible = true
        sizePanelToFittingContent()
        repositionPanelBelow(button: button)
        popoverPanel.orderFront(nil)
        // Cocoa frame → CG coords for `screencapture -R`.
        if let screen = popoverPanel.screen ?? NSScreen.main {
            let cocoaFrame = popoverPanel.frame
            let screenHeight = screen.frame.height
            let cgTop = screenHeight - cocoaFrame.origin.y - cocoaFrame.size.height
            FileHandle.standardError.write(
                "popover-frame: \(Int(cocoaFrame.origin.x)),\(Int(cgTop)),\(Int(cocoaFrame.size.width)),\(Int(cocoaFrame.size.height))\n"
                    .data(using: .utf8) ?? Data()
            )
        }
    }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRight = event?.type == .rightMouseUp
        let isCtrlClick = event?.modifierFlags.contains(.control) == true
        if isRight || isCtrlClick {
            presentContextMenu(from: sender)
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popoverPanel.isVisible {
            popoverPanel.orderOut(nil)
            return
        }
        // If `resignKey` just dismissed the panel, this click is the
        // user closing it — not opening it again.
        if let last = lastDismissAt, Date().timeIntervalSince(last) < Self.dismissDebounce {
            lastDismissAt = nil
            return
        }
        sizePanelToFittingContent()
        repositionPanelBelow(button: sender)
        popoverPanel.makeKeyAndOrderFront(nil)
    }

    /// Pin the panel below the status-item button with a 4pt air gap.
    /// X is clamped into the button's screen so a status item near the
    /// right edge (or crowded by other items) can't push the panel
    /// partially offscreen.
    private func repositionPanelBelow(button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        let buttonRectInWindow = button.convert(button.bounds, to: nil)
        let buttonRectOnScreen = buttonWindow.convertToScreen(buttonRectInWindow)
        let panelSize = popoverPanel.frame.size
        var x = buttonRectOnScreen.midX - panelSize.width / 2
        let screen = buttonWindow.screen
            ?? NSScreen.screens.first { $0.frame.intersects(buttonRectOnScreen) }
        if let screen {
            let visible = screen.visibleFrame
            let minX = visible.minX + 8
            let maxX = visible.maxX - panelSize.width - 8
            // maxX < minX only if the panel is wider than the screen —
            // then keep the centered origin rather than clamping badly.
            if maxX >= minX {
                x = min(max(x, minX), maxX)
            }
        }
        let origin = NSPoint(
            x: x,
            y: buttonRectOnScreen.minY - panelSize.height - 4
        )
        popoverPanel.setFrameOrigin(origin)
    }

    private func repositionPanelBelowStatusItem() {
        guard let button = statusItem.button else { return }
        repositionPanelBelow(button: button)
    }

    /// Size the panel to the SwiftUI card's current fitting height WITHOUT
    /// animation. Called before showing the popover so it opens at the right
    /// size (the card is a subview now, not an auto-resizing content view — see
    /// the crash note where the container is built). Width is fixed
    /// (`PopoverView` is 340pt), so only the height tracks the content.
    private func sizePanelToFittingContent() {
        popoverHost.view.layoutSubtreeIfNeeded()
        let height = popoverHost.view.fittingSize.height
        guard height > 1 else { return }
        var frame = popoverPanel.frame
        frame.size.height = height
        popoverPanel.setFrame(frame, display: false, animate: false)
    }

    /// Resize the visible panel to a new content height, NON-animated. This is
    /// the whole point of the crash fix: an animated hosting-window resize
    /// re-resolves the popover's Liquid Glass every frame and faults in
    /// DesignLibrary on macOS 26.5.1. `setFrame(animate: false)` changes the
    /// window in one step, so the glass resolves once, outside any animation
    /// group. The top edge stays pinned (the card grows downward from the
    /// menubar) and we re-anchor under the status item afterwards.
    private func resizePanelToContentHeight(_ height: CGFloat) {
        guard height > 1, abs(popoverPanel.frame.height - height) > 0.5 else { return }
        var frame = popoverPanel.frame
        frame.origin.y = frame.maxY - height   // pin the top edge
        frame.size.height = height
        popoverPanel.setFrame(frame, display: true, animate: false)
        if popoverPanel.isVisible {
            repositionPanelBelowStatusItem()
        }
    }

    // MARK: - Context menu

    private func presentContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu(title: "Unison")
        menu.autoenablesItems = false

        let header = NSMenuItem(
            title: statusText(for: state),
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // Keyboard equivalents here are cosmetic — global hotkeys
        // are owned by `HotkeyService`. A paused session is still
        // running (auto-resumes when the network returns), so its
        // toggle action — and therefore the title — is "stop".
        let isSessionRunning = state == .active || state == .paused
        let startStop = NSMenuItem(
            title: isSessionRunning ? "Остановить перевод" : "Начать перевод",
            action: #selector(menuStartStop(_:)),
            keyEquivalent: "u"
        )
        startStop.keyEquivalentModifierMask = [.control, .option]
        startStop.target = self
        menu.addItem(startStop)

        let showTranscript = NSMenuItem(
            title: "Показать транскрипт",
            action: #selector(menuShowTranscript(_:)),
            keyEquivalent: "t"
        )
        showTranscript.keyEquivalentModifierMask = [.control, .option]
        showTranscript.target = self
        menu.addItem(showTranscript)

        let history = NSMenuItem(
            title: "История…",
            action: #selector(menuShowHistory(_:)),
            keyEquivalent: ""
        )
        history.target = self
        menu.addItem(history)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Настройки…",
            action: #selector(menuOpenSettings(_:)),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        let diagnostic = NSMenuItem(
            title: "Диагностика…",
            action: #selector(menuShowDiagnostic(_:)),
            keyEquivalent: ""
        )
        diagnostic.target = self
        menu.addItem(diagnostic)

        let about = NSMenuItem(
            title: "О приложении",
            action: #selector(menuShowAbout(_:)),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Завершить Unison",
            action: #selector(menuQuit(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = [.command]
        quit.target = self
        menu.addItem(quit)

        // AppKit windows are bottom-up, so (0, minY-2) anchors the
        // menu *under* the button on every screen, including notched.
        let point = NSPoint(x: 0, y: sender.bounds.minY - 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    private func statusText(for state: MenubarState) -> String {
        switch state {
        case .idle:   return "готов"
        case .active: return "активно"
        case .paused: return "на паузе"
        case .error:  return "ошибка"
        }
    }

    // MARK: - Menu actions

    @objc private func menuStartStop(_ sender: NSMenuItem) { onStartStop?() }
    @objc private func menuShowTranscript(_ sender: NSMenuItem) { onShowTranscript?() }
    @objc private func menuOpenSettings(_ sender: NSMenuItem) { onOpenSettings?() }
    @objc private func menuShowDiagnostic(_ sender: NSMenuItem) { onShowDiagnostic?() }
    @objc private func menuShowHistory(_ sender: NSMenuItem) { onShowHistory?() }
    @objc private func menuShowAbout(_ sender: NSMenuItem) { onShowAbout?() }
    @objc private func menuQuit(_ sender: NSMenuItem) { onQuit?() }

    private func applyState() {
        guard let button = statusItem.button else { return }
        button.image = MenubarIcons.image(for: state)
    }
}

/// Borderless NSPanel for the menubar popover. `canBecomeKey = true`
/// so the panel actually becomes key on show — without it `resignKey`
/// never fires and the auto-dismiss path is dead.
@MainActor
private final class MenubarPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var forceVisible: Bool = false

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        guard !forceVisible else { return }
        orderOut(nil)
        onResignKey?()
    }
}
