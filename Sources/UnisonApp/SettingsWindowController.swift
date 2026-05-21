import AppKit
import SwiftUI
import UnisonUI

/// Hosts the Settings `NSWindow`. Bridges `SettingsView` from `UnisonUI`
/// (which cannot reach AppKit) into a real native window with traffic
/// lights, transparent titlebar, and a hosting controller.
///
/// Plan §5.3:
/// - 560×540 fixed window size (matches `design/settings-final/index.html`).
/// - `titlebarAppearsTransparent = true`, `titleVisibility = .hidden` —
///   the SwiftUI titlebar provides the "Unison · Настройки" text and
///   the SaveIndicator. We just keep the native traffic lights.
/// - The window is non-modal, can be closed with the red button or
///   ESC. Re-opening reuses the same instance.
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
            // `.titled + .fullSizeContentView + titlebarAppearsTransparent`
            // hides the titlebar bar while keeping the traffic lights
            // visible (Settings windows need them per HIG). The SwiftUI
            // content extends beneath the titlebar so the whole window
            // reads as one continuous glass card.
            //
            // Transparency is critical so the macOS 26 Liquid Glass
            // surfaces inside (Form.grouped sections) can refract the
            // real desktop wallpaper instead of sitting on an opaque
            // NSWindow fill.
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
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
            w.hasShadow = true // Compositor-drawn shadow for the floating window.

            // Traffic lights stay visible (close button works).
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true

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
