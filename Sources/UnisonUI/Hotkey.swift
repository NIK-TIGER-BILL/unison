import Foundation

/// Value type describing a global hotkey combo, expressed without any
/// AppKit dependency so it can live in `UnisonUI`. The host (`UnisonApp`)
/// is responsible for translating modifiers and key characters into the
/// platform's actual NSEvent / Carbon representation when registering.
public struct Hotkey: Equatable, Hashable, Codable, Sendable {
    public let modifiers: Set<HotkeyModifier>
    /// One-character identifier of the key (uppercase Latin letters,
    /// digits, or one of a small set of named keys like "space", "left",
    /// "right", "up", "down", "return", "tab"). Used for serialization
    /// and as the fallback display when no `glyph` is known.
    public let keyChar: String
    /// Optional display glyph — e.g. "↑", "↓", "↵", "␣". When `nil`,
    /// `display` falls back to the uppercased `keyChar`.
    public let glyph: String?

    public init(modifiers: Set<HotkeyModifier>, keyChar: String, glyph: String? = nil) {
        self.modifiers = modifiers
        self.keyChar = keyChar
        self.glyph = glyph
    }

    /// Human-readable representation, e.g. `⌃⌥U`, `⌘↑`, `⇧␣`.
    /// Modifier order matches macOS convention: ⌃ ⌥ ⇧ ⌘.
    public var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += glyph ?? keyChar.uppercased()
        return s
    }
}

/// Modifier keys, ordered as macOS conventionally renders them
/// (control, option, shift, command).
public enum HotkeyModifier: String, CaseIterable, Codable, Sendable {
    case control
    case option
    case shift
    case command
}
