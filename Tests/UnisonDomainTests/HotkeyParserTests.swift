import Testing
@testable import UnisonUI

// MARK: - Parser rules

@Test func hotkeyParser_requiresAtLeastOneModifier() {
    let hk = HotkeyParser.parse(modifiers: [], keyChar: "U")
    #expect(hk == nil)
}

@Test func hotkeyParser_acceptsSingleModifier() {
    let hk = HotkeyParser.parse(modifiers: [.command], keyChar: "S")
    #expect(hk != nil)
    #expect(hk?.display == "⌘S")
}

@Test func hotkeyParser_acceptsMultipleModifiers() {
    let hk = HotkeyParser.parse(modifiers: [.control, .option], keyChar: "U")
    #expect(hk?.display == "⌃⌥U")
}

@Test func hotkeyParser_rejectsEscape() {
    let hk = HotkeyParser.parse(modifiers: [.command], keyChar: "escape")
    #expect(hk == nil)
}

@Test func hotkeyParser_rejectsEmptyString() {
    let hk = HotkeyParser.parse(modifiers: [.command], keyChar: "")
    #expect(hk == nil)
}

// MARK: - Glyph mapping

@Test func hotkeyParser_uppercasesLatinKey() {
    let hk = HotkeyParser.parse(modifiers: [.command], keyChar: "u")
    #expect(hk?.display == "⌘U")
}

@Test func hotkeyParser_mapsSpaceToOpenBox() {
    let hk = HotkeyParser.parse(modifiers: [.shift], keyChar: " ")
    #expect(hk?.display == "⇧␣")
}

@Test func hotkeyParser_mapsArrowKeys() {
    #expect(HotkeyParser.parse(modifiers: [.command], keyChar: "up")?.display    == "⌘↑")
    #expect(HotkeyParser.parse(modifiers: [.command], keyChar: "down")?.display  == "⌘↓")
    #expect(HotkeyParser.parse(modifiers: [.command], keyChar: "left")?.display  == "⌘←")
    #expect(HotkeyParser.parse(modifiers: [.command], keyChar: "right")?.display == "⌘→")
}

@Test func hotkeyParser_mapsReturn() {
    let hk = HotkeyParser.parse(modifiers: [.command], keyChar: "return")
    #expect(hk?.display == "⌘↵")
}

@Test func hotkeyParser_mapsTab() {
    let hk = HotkeyParser.parse(modifiers: [.command], keyChar: "tab")
    #expect(hk?.display == "⌘⇥")
}

// MARK: - Modifier ordering

@Test func hotkey_modifierOrder_followsMacConvention() {
    // Order: ⌃ ⌥ ⇧ ⌘ regardless of insertion order.
    let hk = Hotkey(modifiers: [.command, .shift, .control, .option], keyChar: "A")
    #expect(hk.display == "⌃⌥⇧⌘A")
}

// MARK: - Codable round-trip

@Test func hotkey_codableRoundTrip() throws {
    let original = Hotkey(modifiers: [.control, .option], keyChar: "U")
    let decoded = try encodeDecode(original)
    #expect(decoded == original)
}
