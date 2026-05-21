import SwiftUI

/// "Ghost underline" search input used at the top of portal-style
/// dropdowns (language picker, device picker).
///
/// Visual spec (mirrors `design/popover-final`):
/// - leading 11pt magnifyingglass icon
/// - plain text field with 12.5pt body text
/// - 7pt vertical padding, 10pt horizontal padding
/// - 0.5pt bottom rule that brightens on focus
///
/// The component owns its own `@FocusState` so the rule colour follows
/// keyboard focus without parent wiring. Callers bind `text`.
public struct SearchField: View {
    @Binding public var text: String
    public let placeholder: String
    /// Auto-focus the field when the view appears. Useful for floating
    /// pickers that pop up on tap. Defaults to `true`.
    public let autoFocus: Bool

    public init(
        text: Binding<String>,
        placeholder: String = "Найти…",
        autoFocus: Bool = true
    ) {
        self._text = text
        self.placeholder = placeholder
        self.autoFocus = autoFocus
    }

    @FocusState private var focused: Bool

    public var body: some View {
        // HIG Materials: the dropdown sits on `.liquidGlass`. Vibrant
        // `.primary` for the focused state and the typed text, with
        // `.secondary` for the unfocused glyph — the system handles
        // light/dark and Increase Contrast for both.
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(focused ? .primary : .secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary)
                .focused($focused)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(UnisonColors.whiteAlpha(focused ? 0.32 : 0.12))
                .frame(height: 0.5)
                .padding(.horizontal, 2)
        }
        .onAppear {
            if autoFocus { focused = true }
        }
    }
}
