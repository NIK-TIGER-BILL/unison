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
            // Chromeless rounded Liquid Glass card — matches the
            // visual language of Onboarding / Transcript / Diagnostic.
            // The user explicitly asked for this style instead of the
            // previous `.titled` window: "пусть будет liquidGlass".
            //
            // `[.titled, .resizable, .fullSizeContentView, .closable,
            // .miniaturizable]` + transparent titlebar + hidden
            // traffic lights gets us the chromeless card *and* keeps
            // resize, Cmd+W close, and Cmd+M minimize working through
            // the system. Pure `.borderless` would lose all of those.
            //
            // `.fullSizeContentView` lets the SwiftUI content extend
            // through the (invisible) titlebar band so the glass card
            // is unbroken top-to-bottom. The form rows then need a top
            // inset to avoid landing under the hidden traffic-light
            // hit area — handled in SettingsView via padding.
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            // Internal title — never visible (titleVisibility=.hidden)
            // but used by the screenshot harness to locate the window.
            w.title = "Unison · Настройки"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            // Hide the three traffic-light buttons so the card looks
            // unified. Cmd+W still closes (handled by .closable).
            w.standardWindowButton(.closeButton)?.isHidden = true
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isReleasedWhenClosed = false
            w.isMovableByWindowBackground = true
            // Liquid Glass: transparent window so the NSVisualEffectView
            // below shows through; the compositor's behind-window
            // blend pass recomputes blur in real time as content
            // behind the window changes.
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.minSize = NSSize(width: 560, height: 480)
            w.maxSize = NSSize(width: 800, height: 1200)

            let root = SettingsView(
                vm: viewModel,
                onOpenURL: onOpenURL,
                onRecordHotkey: onRecordHotkey,
                onClose: { [weak w] in w?.performClose(nil) }
            )
            let host = NSHostingController(rootView: root)
            host.view.translatesAutoresizingMaskIntoConstraints = false

            // Liquid Glass backing. `.windowBackground` material on
            // macOS Tahoe renders the canonical translucent Liquid
            // Glass surface. The rounded mask gives the card its
            // silhouette; the system shadow underneath was set
            // above via `w.hasShadow`.
            let veView = NSVisualEffectView()
            // `.hudWindow` is the canonical Liquid Glass material on
            // macOS Tahoe (the same one used by Notification Center,
            // Spotlight, Control Center). `.windowBackground` renders
            // as a near-opaque panel on Tahoe — the user reported
            // "Полностью серый фон" with that material. `.hudWindow`
            // is genuinely translucent and refracts the wallpaper.
            veView.material = .hudWindow
            veView.blendingMode = .behindWindow
            veView.state = .active
            veView.wantsLayer = true
            veView.layer?.cornerRadius = 22
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
