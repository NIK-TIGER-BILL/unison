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
/// - `styleMask` includes `.titled`, `.closable`, `.miniaturizable`,
///   `.fullSizeContentView`. All three traffic lights are visible and
///   functional, matching every other System Settings-style window.
/// - `title = "Unison · Настройки"` and `titleVisibility = .visible`
///   so the native titlebar renders the document title — no custom
///   `Text("Unison · Настройки")` inside SwiftUI.
/// - `backgroundColor = NSColor.windowBackgroundColor` is a system
///   dynamic colour that on macOS 26 picks up the Liquid Glass window
///   material; it adapts automatically to light/dark mode and to
///   `Reduce Transparency`. We just have to ask for it.
/// - `isOpaque = false` lets that material refract the desktop wallpaper.
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
            // - `.fullSizeContentView`: lets the SwiftUI content extend
            //   beneath the titlebar so scroll edges blur through it.
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            w.title = "Unison · Настройки"
            w.titleVisibility = .visible
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            // `NSColor.windowBackgroundColor` is a system dynamic colour
            // that supplies the macOS 26 Tahoe window material — glass
            // with adaptive translucency that reacts to Reduce
            // Transparency and Increase Contrast automatically. We rely
            // on this instead of a custom `.glassEffect` wrapper.
            w.backgroundColor = NSColor.windowBackgroundColor
            w.isOpaque = false
            w.hasShadow = true

            let root = SettingsView(
                vm: viewModel,
                onOpenURL: onOpenURL,
                onRecordHotkey: onRecordHotkey
            )
            w.contentViewController = NSHostingController(rootView: root)
            window = w
        }
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
