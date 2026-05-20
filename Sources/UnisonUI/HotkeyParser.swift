import Foundation

/// Pure-Swift utilities for building / validating `Hotkey` values without
/// touching AppKit. The host application converts `NSEvent` modifier flags
/// and key codes into the inputs accepted here, then forwards the result
/// to whatever native registration API is in use (Carbon, CoreGraphics, …).
public enum HotkeyParser {
    /// Try to construct a `Hotkey` from a modifier set and a key character.
    ///
    /// Rules (mirroring the design HTML's `kbd-recorder`):
    /// - At least one modifier among ⌃ ⌥ ⇧ ⌘ is **required** — bare keys
    ///   are rejected to avoid accidental swallow of normal typing.
    /// - `keyChar` must not be empty. Whitespace-only strings are mapped
    ///   to the `space` glyph.
    /// - Common navigation keys (arrows, return, tab, escape, space) get a
    ///   prettier display glyph.
    public static func parse(modifiers: Set<HotkeyModifier>, keyChar: String) -> Hotkey? {
        guard !modifiers.isEmpty else { return nil }
        let trimmed = keyChar.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyChar.isEmpty else { return nil }
        // Escape cancels recording — caller treats `nil` as cancel; we
        // refuse to build a hotkey from it. (The escape key is also
        // ambiguous as a hotkey; reserve it.)
        if trimmed.lowercased() == "escape" || trimmed == "\u{1B}" {
            return nil
        }
        let (canonical, glyph) = canonicalize(keyChar)
        return Hotkey(modifiers: modifiers, keyChar: canonical, glyph: glyph)
    }

    /// Normalizes a raw key character into `(canonical, glyph)` for storage
    /// and display. Returns the original character (uppercased) plus
    /// optional pretty glyph for the limited set of named keys we render.
    static func canonicalize(_ raw: String) -> (canonical: String, glyph: String?) {
        let lower = raw.lowercased()
        switch lower {
        case " ", "space":   return ("space", "␣")
        case "left":         return ("left",  "←")
        case "right":        return ("right", "→")
        case "up":           return ("up",    "↑")
        case "down":         return ("down",  "↓")
        case "return", "enter", "\r", "\n":
            return ("return", "↵")
        case "tab", "\t":    return ("tab",   "⇥")
        case "delete", "\u{7F}", "\u{08}":
            return ("delete", "⌫")
        default:
            // Single-character key (Latin letter, digit, punctuation):
            // render uppercase, no glyph.
            if raw.count == 1 {
                return (raw.uppercased(), nil)
            }
            // Multi-character custom name (e.g. "f1") — pass through.
            return (lower, nil)
        }
    }
}
