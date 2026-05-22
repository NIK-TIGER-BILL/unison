import SwiftUI

/// Password-style text input with a "Показать / Скрыть" text toggle on the
/// right (per design — eye-icon was explicitly rejected). DESIGN.md §5.16.
///
/// On macOS 26 the simpler layout (no `Group` wrapper, no explicit height
/// frames, no placeholder gymnastics) renders correctly: the TextField /
/// SecureField swap stays in the leading slot of the HStack, the toggle
/// label sits on the trailing edge, and the row's intrinsic height drives
/// the container so the two field types stay vertically aligned without
/// pinning a magic height value.
public struct SecretInput: View {
    @Binding public var text: String
    public let placeholder: String

    public init(text: Binding<String>, placeholder: String = "") {
        self._text = text
        self.placeholder = placeholder
    }

    @SwiftUI.State private var isVisible = false
    @FocusState private var fieldFocused: Bool

    public var body: some View {
        HStack(spacing: 8) {
            field
                .textFieldStyle(.plain)
                .font(UnisonFonts.mono(11.5))
                .tracking(0.4)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .focused($fieldFocused)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: { isVisible.toggle() }) {
                Text(isVisible ? "Скрыть" : "Показать")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(UnisonColors.whiteAlpha(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    fieldFocused
                        ? UnisonColors.whiteAlpha(0.32)
                        : UnisonColors.whiteAlpha(0.10),
                    lineWidth: 0.5
                )
        )
    }

    /// The TextField / SecureField swap lives in its own `@ViewBuilder`
    /// instead of an inline `Group { … }`. Group introduces a wrapper
    /// container that macOS 26 sometimes lays out as a vertical stack
    /// (the rendered value drifts onto a second line below the placeholder),
    /// the simpler builder-returned view participates directly in the
    /// surrounding HStack.
    @ViewBuilder
    private var field: some View {
        if isVisible {
            TextField(placeholder, text: $text)
        } else {
            SecureField(placeholder, text: $text)
        }
    }
}
