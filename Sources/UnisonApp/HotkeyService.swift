import AppKit
import Foundation
import UnisonUI

/// Bridges the value-level `Hotkey` configured in `SettingsViewModel` to a
/// real macOS event monitor.
///
/// **Why `NSEvent` and not Carbon `RegisterEventHotKey`?**
/// The plan (`§5.4`) sketches Carbon; we ship `NSEvent` instead for v1
/// because:
/// - it avoids importing `Carbon.HIToolbox` (deprecated for some symbols
///   on macOS 26),
/// - both `addGlobalMonitorForEvents` and `addLocalMonitorForEvents` work
///   today without Accessibility permission for the modifier-rich combos
///   the design ships (`⌃⌥U`, `⌃⌥T`),
/// - it keeps the surface area tiny and testable.
///
/// The service exposes two responsibilities:
/// 1. **Global registration** of currently-configured hotkeys
///    (`updateHotkeys`) that fire `onStartStop` / `onShowTranscript` when
///    the user presses the combo anywhere in the system.
/// 2. **Local capture** during a recording session: while the Settings
///    UI is recording a hotkey, the service installs a *local* monitor
///    that intercepts the next valid keystroke, builds a `Hotkey` via
///    `HotkeyParser.parse(...)`, and feeds it back via the callback the
///    caller provided.
@MainActor
public final class HotkeyService {
    public typealias Action = @MainActor () -> Void

    /// Invoked when the start/stop combo fires globally.
    public var onStartStop: Action?
    /// Invoked when the show-transcript combo fires globally.
    public var onShowTranscript: Action?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var recordingMonitor: Any?

    private var startStopHotkey: Hotkey?
    private var showTranscriptHotkey: Hotkey?

    public init() {}

    // No `deinit` cleanup — `NSEvent.removeMonitor` is main-actor work in
    // strict Swift 6 concurrency and `deinit` is non-isolated. The
    // service is expected to live as long as the app; callers that
    // want explicit teardown call `stop()`.

    // MARK: - Registration

    /// Install the global key-down monitor. Safe to call multiple times —
    /// subsequent calls are no-ops if a monitor is already installed.
    public func start() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                Task { @MainActor in self?.handleGlobalKeyDown(event) }
            }
        }
        // A local monitor catches the same event when the Unison
        // popover/settings window is itself the key window, so combos
        // still work without leaving the app.
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = self?.handleGlobalKeyDown(event) ?? false
                return consumed ? nil : event
            }
        }
    }

    /// Remove the monitor. Recording (if active) is cancelled.
    public func stop() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
        endRecording()
    }

    /// Replace the registered hotkeys. Both can be `nil` to clear.
    public func updateHotkeys(startStop: Hotkey?, showTranscript: Hotkey?) {
        self.startStopHotkey = startStop
        self.showTranscriptHotkey = showTranscript
    }

    // MARK: - Recording

    /// Begin a local-event monitor that intercepts the next valid keypress
    /// and feeds it back via `onCapture`. Cancelled when the user presses
    /// Escape, when the caller invokes `endRecording()`, or when the next
    /// valid combo lands. `onCancel` fires for Escape or external cancel.
    public func beginRecording(
        onCapture: @escaping @MainActor (Hotkey) -> Void,
        onCancel: @escaping @MainActor () -> Void = {}
    ) {
        endRecording()
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Escape cancels.
            if event.keyCode == 53 {
                Task { @MainActor in
                    self.endRecording()
                    onCancel()
                }
                return nil
            }
            // Build a Hotkey using the modifier mask + first character.
            guard let hotkey = Self.makeHotkey(from: event) else {
                return nil // swallow keys without modifiers so they don't escape
            }
            Task { @MainActor in
                self.endRecording()
                onCapture(hotkey)
            }
            return nil
        }
    }

    /// Tear down the recording monitor if it's installed. Public so
    /// callers can cancel from a click-outside handler.
    public func endRecording() {
        if let m = recordingMonitor {
            NSEvent.removeMonitor(m)
            recordingMonitor = nil
        }
    }

    // MARK: - Event handling

    /// Returns `true` if the event matched a known hotkey (so the local
    /// monitor can swallow it). Always returns `false` for global events
    /// (their return value is ignored by AppKit).
    @discardableResult
    private func handleGlobalKeyDown(_ event: NSEvent) -> Bool {
        guard let pressed = Self.makeHotkey(from: event) else { return false }
        if let target = startStopHotkey, target == pressed {
            onStartStop?()
            return true
        }
        if let target = showTranscriptHotkey, target == pressed {
            onShowTranscript?()
            return true
        }
        return false
    }

    // MARK: - NSEvent → Hotkey

    /// Convert an `NSEvent` (`.keyDown`) into a `Hotkey` if it carries
    /// at least one modifier among ⌃ ⌥ ⇧ ⌘. Returns `nil` for bare
    /// keys (per design) and for purely-modifier events (only Shift /
    /// Control / Option / Command held).
    public static func makeHotkey(from event: NSEvent) -> Hotkey? {
        let mods = modifierSet(from: event.modifierFlags)
        guard !mods.isEmpty else { return nil }
        let raw = canonicalCharacter(for: event)
        guard !raw.isEmpty else { return nil }
        return HotkeyParser.parse(modifiers: mods, keyChar: raw)
    }

    /// Translate AppKit's `NSEvent.ModifierFlags` into the
    /// presentation-layer `HotkeyModifier` set (no AppKit dependency).
    private static func modifierSet(from flags: NSEvent.ModifierFlags) -> Set<HotkeyModifier> {
        var s = Set<HotkeyModifier>()
        if flags.contains(.control) { s.insert(.control) }
        if flags.contains(.option)  { s.insert(.option) }
        if flags.contains(.shift)   { s.insert(.shift) }
        if flags.contains(.command) { s.insert(.command) }
        return s
    }

    /// Pull a representative one-character (or named) key out of the
    /// event. We prefer `charactersIgnoringModifiers` so that ⌥-U does
    /// not become "˙" (the Option-U dead key on US keyboards), then
    /// map a small set of named keys to the canonical name accepted
    /// by `HotkeyParser`.
    private static func canonicalCharacter(for event: NSEvent) -> String {
        // Named keys we special-case (arrows, return, tab, escape, …).
        switch event.keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 49: return " "
        case 51: return "delete"
        case 53: return "escape"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default: break
        }
        // Function keys (F1=122, F2=120, F3=99, F4=118, F5=96, F6=97,
        // F7=98, F8=100, F9=101, F10=109, F11=103, F12=111).
        if let fn = Self.functionKeyName(for: event.keyCode) {
            return fn
        }
        let raw = event.charactersIgnoringModifiers ?? event.characters ?? ""
        return raw
    }

    private static func functionKeyName(for keyCode: UInt16) -> String? {
        let map: [UInt16: Int] = [
            122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6,
            98: 7, 100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        ]
        guard let n = map[keyCode] else { return nil }
        return "f\(n)"
    }
}
