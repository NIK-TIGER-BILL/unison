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
        onShowAbout: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = { NSApp.terminate(nil) }
    ) {
        self.popoverVM = popoverVM
        self.onOpenSettings = onOpenSettings
        self.onStartStop = onStartStop
        self.onShowTranscript = onShowTranscript
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
            rootView: PopoverView(vm: popoverVM, onOpenSettings: { [popoverRef] in
                // Dismiss the popover before opening Settings so it
                // doesn't sit on top of the new window.
                popoverRef.performClose(nil)
                onOpenSettings()
            })
        )
        host.sizingOptions = [.preferredContentSize]
        popover.contentSize = NSSize(width: 340, height: 320)
        popover.contentViewController = host

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
    @objc private func menuShowAbout(_ sender: NSMenuItem) { onShowAbout?() }
    @objc private func menuQuit(_ sender: NSMenuItem) { onQuit?() }

    // MARK: - Internal

    private func applyState() {
        guard let button = statusItem.button else { return }
        button.image = MenubarIcons.image(for: state)
    }
}
