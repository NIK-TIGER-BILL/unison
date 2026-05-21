import SwiftUI

/// Password-style text input with a "Показать / Скрыть" text toggle on the
/// right (per design — eye-icon was explicitly rejected). DESIGN.md §5.16.
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
        // HIG Materials: vibrant `.primary` for the typed mono key
        // text and `.secondary` for the inline "Показать / Скрыть"
        // toggle label.
        //
        // The `Group { TextField | SecureField }` swap is what visually
        // toggles the dots vs. plaintext rendering. Both controls have
        // slightly different intrinsic heights and baseline metrics, so
        // without an explicit container height the placeholder
        // `sk-proj-…` jumps up/down a couple of points when the user
        // taps "Показать / Скрыть". Pinning the field group to a fixed
        // 18pt height (the natural rendered height of the mono 11.5
        // glyphs at our padding) keeps the input row visually stable
        // across both modes.
        HStack(spacing: 8) {
            Group {
                if isVisible {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(UnisonFonts.mono(11.5))
            .tracking(0.4)
            .foregroundStyle(.primary)
            .focused($fieldFocused)
            .frame(height: 18)

            Button {
                isVisible.toggle()
            } label: {
                Text(isVisible ? "Скрыть" : "Показать")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
                    .padding(.horizontal, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.clear)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
        .padding(.leading, 9)
        .padding(.trailing, 6)
        // Stable container height — guards against intrinsic-size
        // differences between `TextField` and `SecureField` shifting
        // the row vertically on toggle. 26pt = 18pt field + 4pt × 2
        // vertical padding.
        .frame(height: 26)
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
}

