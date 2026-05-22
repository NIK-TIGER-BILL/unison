import AppKit
import SwiftUI
import UnisonUI

/// Hosts the Settings `NSWindow`. Bridges `SettingsView` from `UnisonUI`
/// (which cannot reach AppKit) into a real native window with the
/// standard macOS Settings chrome — titled window, system titlebar,
/// translucent material background.
///
/// We deliberately fall back on Apple's defaults for window styling
/// instead of a hand-rolled glass container:
///
/// - `styleMask` is `.titled | .closable | .miniaturizable`. We do
///   **not** opt into `.fullSizeContentView`: the native titlebar
///   reserves its own layout band (so SwiftUI content can never
///   draw under it) and renders with the system Liquid Glass
///   material exactly like System Settings.
/// - `title = "Unison · Настройки"` and `titleVisibility = .visible`
///   so the native titlebar renders the document title — no custom
///   `Text("Unison · Настройки")` inside SwiftUI.
/// - `backgroundColor = NSColor.windowBackgroundColor` is a system
///   dynamic colour that on macOS 26 picks up the Liquid Glass window
///   material; it adapts automatically to light/dark mode and to
///   `Reduce Transparency`. We just have to ask for it.
///
/// `Form { … }.formStyle(.grouped)` inside `SettingsView` then renders
/// the rounded section cards on top, matching native System Settings.
///
/// `onRecordHotkey` wiring:
/// AppDelegate creates one `HotkeyService`; when the user taps a
/// `HotkeyRecorder` in `SettingsView`, the view calls our
/// `onRecordHotkey: (HotkeyKind) -> Void` closure. The closure invokes
/// `hotkeyService.beginRecording { hotkey in vm.updateHotkey(kind, hotkey) }`,
/// closing the loop without leaking AppKit into `UnisonUI`.
@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let viewModel: SettingsViewModel
    private let onRecordHotkey: (HotkeyKind) -> Void
    private let onOpenURL: (URL) -> Void

    public init(
        viewModel: SettingsViewModel,
        onRecordHotkey: @escaping (HotkeyKind) -> Void = { _ in },
        onOpenURL: @escaping (URL) -> Void = { url in NSWorkspace.shared.open(url) }
    ) {
        self.viewModel = viewModel
        self.onRecordHotkey = onRecordHotkey
        self.onOpenURL = onOpenURL
    }

    public func show() {
        if window == nil {
            // Standard macOS Settings-style window:
            // - `.titled`: native titlebar with the document title.
            // - `.closable` / `.miniaturizable`: all three traffic lights.
            // - `.resizable`: user can resize the Settings window to fit
            //   their display. Native Form supplies an internal scroll
            //   view so reducing the height shows a scroll indicator
            //   instead of clipping rows.
            //
            // We deliberately omit `.fullSizeContentView`: with that flag
            // SwiftUI content extends under the titlebar and the system
            // does not auto-inset, so the first row of the Form covers
            // the title text and the traffic lights (the user's bug
            // report). Without the flag, AppKit reserves the titlebar
            // band on its own and the form starts directly below it,
            // matching every other System Settings-style window on
            // Tahoe.
            //
            // Default height is 620pt — the standard macOS System
            // Settings pane height — so the window fits comfortably on
            // any display out of the box. The Form's internal scroll
            // view handles overflow, and the user can drag the bottom
            // edge to expand the window if they want every section
            // visible at once.
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            w.title = "Unison · Настройки"
            w.titleVisibility = .visible
            // Standard titlebar (not transparent): on macOS 26 the
            // titlebar renders with the system Liquid Glass material
            // and a faint divider beneath it, the same chrome System
            // Settings uses. Making it transparent breaks that
            // composition.
            w.titlebarAppearsTransparent = false
            w.isReleasedWhenClosed = false
            // Liquid Glass requires an explicit `NSVisualEffectView`
            // backing on macOS 26: `NSColor.windowBackgroundColor` in
            // light mode is a solid grey, not the translucent material
            // System Settings uses. We back the window with
            // `NSVisualEffectView(material: .windowBackground)` and
            // make the window itself transparent so the visual effect
            // shows through. The Form's own scroll-content background
            // is hidden below in `SettingsView` so the glass is visible
            // beneath the section cards.
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            // Min/max bounds: the smaller end keeps the form usable on
            // 13" displays (sections still readable, no horizontal
            // squish); the upper bound prevents accidental over-expand
            // on multi-monitor setups.
            w.minSize = NSSize(width: 560, height: 480)
            w.maxSize = NSSize(width: 800, height: 1200)

            let root = SettingsView(
                vm: viewModel,
                onOpenURL: onOpenURL,
                onRecordHotkey: onRecordHotkey
            )
            let host = NSHostingController(rootView: root)
            host.view.translatesAutoresizingMaskIntoConstraints = false

            // Liquid Glass backing for the window content area. With
            // `.windowBackground` material, `NSVisualEffectView`
            // resolves to the system Liquid Glass material on Tahoe —
            // the same translucent surface System Settings draws on,
            // which refracts the desktop wallpaper and sibling windows
            // behind the window.
            let veView = NSVisualEffectView()
            veView.material = .windowBackground
            veView.blendingMode = .behindWindow
            veView.state = .active
            veView.translatesAutoresizingMaskIntoConstraints = false
            veView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: veView.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: veView.bottomAnchor),
                host.view.leadingAnchor.constraint(equalTo: veView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: veView.trailingAnchor),
            ])

            w.contentView = veView
            // We're setting the content view directly (not via
            // controller) so the visual effect view stays the root —
            // a contentViewController would replace it on demand.
            w.contentViewController = nil
            w.setContentSize(NSSize(width: 560, height: 620))
            w.center()
            window = w
        }
        // Re-probe the registry on every show. The CoreAudio listener
        // already pushes device-change events into the VM, but if the
        // window was last opened before that listener was wired (rare
        // launch race) — or if the user just unplugged something with
        // the window closed — we want the freshest snapshot the moment
        // it appears.
        viewModel.refreshDeviceList()
        viewModel.refreshBlackHoleStatus()

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        // Ensure we steal focus from the menubar popover so the
        // keyboard shortcuts (and recording monitor) get key events.
        NSApp.activate(ignoringOtherApps: true)
    }

    public func close() {
        window?.orderOut(nil)
    }

    /// Forwarded to the underlying window — used by AppDelegate when
    /// the user clicks somewhere else and we need to dismiss a
    /// recording session that's still listening.
    public var isVisible: Bool {
        window?.isVisible ?? false
    }
}
