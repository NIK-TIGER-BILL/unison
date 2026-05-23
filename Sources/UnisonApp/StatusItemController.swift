import AppKit
import SwiftUI
import UnisonDomain
import UnisonUI

/// Owns the menubar `NSStatusItem` and dispatches clicks:
/// - **Left click** → toggles the popover hosting `PopoverView`.
/// - **Right click / Cmd-click** → opens a context `NSMenu` with the
///   actions sketched in `design/menubar-final/index.html` §"context-menu"
///   (status header, start/stop, show transcript, settings, about, quit).
///
/// The icon image reflects an externally-driven `MenubarState`:
///
/// ```swift
/// statusItemController.state = .active
/// ```
///
/// `AppDelegate` observes the orchestrator's `SessionState` and pushes a
/// `MenubarState` here on every change.
@MainActor
public final class StatusItemController {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let popoverVM: PopoverViewModel

    /// Callbacks dispatched from context-menu items. All optional so the
    /// controller stays usable in previews / tests where wiring is partial.
    public var onStartStop: (() -> Void)?
    public var onShowTranscript: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    public var onShowDiagnostic: (() -> Void)?
    public var onShowAbout: (() -> Void)?
    public var onQuit: (() -> Void)?

    /// Current visual state. Setting this updates the status-item button
    /// image. Defaults to `.idle` at construction.
    public var state: MenubarState = .idle {
        didSet {
            guard state != oldValue else { return }
            applyState()
        }
    }

    public init(
        popoverVM: PopoverViewModel,
        onOpenSettings: @escaping () -> Void = {},
        onStartStop: @escaping () -> Void = {},
        onShowTranscript: @escaping () -> Void = {},
        onShowDiagnostic: @escaping () -> Void = {},
        onShowAbout: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.popoverVM = popoverVM
        self.onOpenSettings = onOpenSettings
        self.onStartStop = onStartStop
        self.onShowTranscript = onShowTranscript
        self.onShowDiagnostic = onShowDiagnostic
        self.onShowAbout = onShowAbout
        self.onQuit = onQuit

        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        popover.behavior = .transient
        // Force the popover's container into dark appearance so the
        // SwiftUI `.liquidGlass(...)` panel doesn't sit on top of the
        // system's white vibrancy backdrop (which produced a
        // "window in window" double-chrome effect in earlier builds).
        popover.appearance = NSAppearance(named: .vibrantDark)
        // 340pt width matches the redesigned PopoverView (DESIGN §4.3).
        // Height comes from the SwiftUI ideal size — we enable
        // `preferredContentSize` so the popover grows when the dropdown
        // overlay expands the SwiftUI hierarchy.
        let popoverRef = popover
        let host = NSHostingController(
            rootView: PopoverView(
                vm: popoverVM,
                onOpenSettings: { [popoverRef] in
                    // Dismiss the popover before opening Settings so it
                    // doesn't sit on top of the new window.
                    popoverRef.performClose(nil)
                    onOpenSettings()
                },
                onShowDiagnostic: { [popoverRef, weak self] in
                    // Same pattern as Settings — dismiss the popover so
                    // the diagnostic window doesn't sit behind it.
                    popoverRef.performClose(nil)
                    self?.onShowDiagnostic?()
                }
            )
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: 340, height: 320)
        // Wrap the SwiftUI content in an NSVisualEffectView so the
        // popover's glass is *live* — the compositor's behind-window
        // pass recomputes blur as the wallpaper / underlying windows
        // change. NSPopover paints its own chrome (rounded corners +
        // arrow) so we don't need to manage clipping ourselves.
        // Using `.popover` material gives Apple's canonical popover
        // glass.
        //
        // The wrapper controller forwards the SwiftUI host's
        // `preferredContentSize` to itself so NSPopover's
        // sizing-options machinery keeps working — without that the
        // popover would stay at the initial 340×320 forever even
        // when the SwiftUI content's ideal size grew.
        popover.contentViewController = GlassPopoverWrapperController(host: host, material: .popover)

        if let button = statusItem.button {
            // Listen for both left and right mouse-ups so we can branch
            // between popover and context menu in a single handler.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.action = #selector(handleClick(_:))
            button.target = self
            button.image = MenubarIcons.image(for: state)
            button.imagePosition = .imageOnly
            button.toolTip = "Unison"
        }
    }

    // MARK: - Public state-update entry point

    /// Compatibility shim. Older callers used `setActiveIcon(true/false)`.
    /// `AppDelegate` now sets `.state` directly; this remains so partial
    /// updates from tests / previews still compile.
    @available(*, deprecated, message: "Set `state` directly")
    public func setActiveIcon(_ active: Bool) {
        state = active ? .active : .idle
    }

    /// Programmatically present the popover anchored to the status item
    /// button. Used by the Tart VM screenshot harness
    /// (`UNISON_FORCE_STATE=popover-open`) so we don't depend on
    /// AppleScript clicking the menubar item (which needs Accessibility
    /// permission and traverses a non-obvious AX hierarchy).
    ///
    /// The default `.transient` behavior dismisses on the first event
    /// outside the popover — that races with `screencapture` running
    /// inside the same VM (the OS counts the SSH activation as an
    /// outside event). When the harness calls this we switch behavior
    /// to `.applicationDefined` so the popover stays visible until the
    /// process exits.
    ///
    /// No-op if the popover is already shown or the status item has no
    /// button (e.g. in unit tests without a menu bar).
    public func showPopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { return }
        popover.behavior = .applicationDefined
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Surface the popover's backing NSWindow under a stable title so
        // the Tart screenshot harness can query its frame via
        // `process "Unison" → window "Unison Popover"` in AppleScript and
        // crop the screencapture to just that window's bounds. NSPopover
        // doesn't expose its window until after `show()` runs, hence the
        // assignment here rather than at init.
        popover.contentViewController?.view.window?.title = "Unison Popover"
        // Also log the popover's screen frame to stderr so the harness
        // can fall back to bounds-from-log if AppleScript can't see the
        // window (NSPopover hosts its content in a private panel that
        // accessibility traversal occasionally misses).
        //
        // `NSWindow.frame` is in Cocoa coords (origin = bottom-left,
        // y grows up); `screencapture -R` wants CG coords (origin =
        // top-left, y grows down). Convert by subtracting the window's
        // top edge from the screen height.
        if let window = popover.contentViewController?.view.window,
           let screen = window.screen ?? NSScreen.main {
            let cocoaFrame = window.frame
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
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    // MARK: - Context menu

    /// Build a fresh `NSMenu` per click so item labels reflect the
    /// current `state`. AppKit dismisses popovers automatically when a
    /// menu opens, so we don't need to worry about overlap.
    private func presentContextMenu(from sender: NSStatusBarButton) {
        let menu = NSMenu(title: "Unison")
        menu.autoenablesItems = false

        // Status header — disabled, mirrors `design/menubar-final` ctx
        // header (`"готов"` / `"активно"` / `"на паузе"` / `"ошибка"`).
        let header = NSMenuItem(
            title: statusText(for: state),
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(.separator())

        // Start / Stop — label flips on active state. Keyboard
        // equivalent is purely cosmetic here (NSMenu doesn't trigger
        // global hotkeys, that's HotkeyService's job).
        let startStop = NSMenuItem(
            title: state == .active ? "Остановить перевод" : "Начать перевод",
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

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: "Настройки…",
            action: #selector(menuOpenSettings(_:)),
            keyEquivalent: ","
        )
        settings.keyEquivalentModifierMask = [.command]
        settings.target = self
        menu.addItem(settings)

        // "Диагностика…" sits between Settings and About so it's
        // discoverable but not the first thing users see. Wired to a
        // callback so AppDelegate (the only place that knows about
        // `DiagnosticWindowController`) does the actual presentation.
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

        // Present the menu directly below the status-item button.
        // Anchor at (0, minY-2) in button-local coordinates — AppKit
        // windows are bottom-up so this places the menu *under* the
        // button on every screen, including notched displays.
        let point = NSPoint(x: 0, y: sender.bounds.minY - 2)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    /// Russian status label that appears at the top of the context menu.
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
    @objc private func menuShowAbout(_ sender: NSMenuItem) { onShowAbout?() }
    @objc private func menuQuit(_ sender: NSMenuItem) { onQuit?() }

    // MARK: - Internal

    private func applyState() {
        guard let button = statusItem.button else { return }
        button.image = MenubarIcons.image(for: state)
    }
}

/// View controller that backs the popover with a live
/// `NSVisualEffectView` (Apple's canonical Liquid Glass on macOS 26
/// at the AppKit level — the compositor recomputes its blur every
/// frame as content behind the window changes). The hosted SwiftUI
/// `NSHostingController` becomes a child controller so AppKit's
/// `preferredContentSizeDidChange(for:)` chain wires the SwiftUI
/// ideal-size signal up to NSPopover's resizing logic — without
/// this the popover would freeze at its initial 340×320 even when
/// the SwiftUI content's ideal size grew (e.g. when an error row
/// gets appended).
@MainActor
private final class GlassPopoverWrapperController: NSViewController {
    private let host: NSHostingController<PopoverView>

    init(host: NSHostingController<PopoverView>, material: NSVisualEffectView.Material) {
        self.host = host
        super.init(nibName: nil, bundle: nil)
        addChild(host)
        let veView = NSVisualEffectView()
        veView.material = material
        veView.blendingMode = .behindWindow
        veView.state = .active
        veView.translatesAutoresizingMaskIntoConstraints = false
        host.view.translatesAutoresizingMaskIntoConstraints = false
        veView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: veView.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: veView.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: veView.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: veView.trailingAnchor),
        ])
        view = veView
        preferredContentSize = host.preferredContentSize
    }

    required init?(coder: NSCoder) { nil }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        // Propagate the SwiftUI host's ideal size up so NSPopover
        // resizes whenever the popover content grows / shrinks.
        if viewController === host {
            preferredContentSize = viewController.preferredContentSize
        }
    }
}
