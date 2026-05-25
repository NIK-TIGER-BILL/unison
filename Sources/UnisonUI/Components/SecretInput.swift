import AppKit
import SwiftUI

/// Single-line text input for secret values (API keys), with a
/// "Показать / Скрыть" toggle that swaps between masked dots and
/// plain text.
///
/// **Why this is an AppKit wrapper instead of SwiftUI's `SecureField`.**
///
/// On macOS 26, SwiftUI's built-in `TextField(placeholder:text:)` and
/// `SecureField(placeholder:text:)` render the placeholder as a
/// **persistent leading label** — the hint stays visible even when
/// the field has a value, so the user sees `sk-proj-…` hovering above
/// the masked dots. Three layered SwiftUI-only attempts in this
/// codebase didn't fix it cleanly:
///   1. Drop the placeholder argument → SwiftUI still reserves the
///      vertical band for it, the field stops being one line.
///   2. Empty string placeholder + manual overlay → on some renders
///      the floating label *still* appeared.
///   3. Swap `TextField` ↔ `SecureField` via `@ViewBuilder` → the
///      whole layout shifts because the two views have different
///      intrinsic sizes.
///
/// Wrapping NSSecureTextField / NSTextField directly side-steps all of
/// that. AppKit's secure text field is a 30-year-old battle-tested
/// control: it handles paste, undo, drag-drop, locale, focus ring,
/// dead keys, IME, etc., consistently across every macOS version.
/// SwiftUI's `SecureField` is a thin and inconsistent shim on top.
///
/// **Public API is identical to the previous SwiftUI version**, so
/// call sites in `SettingsView` / `OnboardingView` don't need to
/// change: `SecretInput(text: $apiKey, placeholder: "sk-proj-…")`.
public struct SecretInput: View {
    @Binding public var text: String
    public let placeholder: String

    public init(text: Binding<String>, placeholder: String = "") {
        self._text = text
        self.placeholder = placeholder
    }

    @SwiftUI.State private var isVisible = false
    @SwiftUI.State private var isFocused = false

    public var body: some View {
        HStack(spacing: 8) {
            AppKitSecretField(
                text: $text,
                placeholder: placeholder,
                isSecure: !isVisible,
                isFocused: $isFocused
            )
            // `.id(isVisible)` forces SwiftUI to recreate the underlying
            // NSViewRepresentable when the user toggles "Показать".
            // NSSecureTextField and NSTextField are different classes
            // — there's no in-place transmutation API in AppKit — so
            // recreating is the simplest path. Focus is lost on
            // toggle, but the user just clicked our button anyway.
            .id(isVisible)
            .frame(maxWidth: .infinity)

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
                    isFocused
                        ? UnisonColors.whiteAlpha(0.32)
                        : UnisonColors.whiteAlpha(0.10),
                    lineWidth: 0.5
                )
        )
        .animation(.easeInOut(duration: 0.12), value: isFocused)
    }
}

// MARK: - AppKit-backed implementation

/// NSViewRepresentable bridge for either NSSecureTextField (when
/// `isSecure == true`) or NSTextField (plain). One concrete NSView
/// class per instance; the parent uses `.id(isVisible)` to recreate
/// us on toggle. We don't try to swap classes in place — AppKit
/// has no public API for that, and the workarounds (custom NSView
/// container hosting both subfields) trade simplicity for fragility.
private struct AppKitSecretField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure
            ? NSSecureTextField(frame: .zero)
            : NSTextField(frame: .zero)

        // Chromeless: the surrounding SwiftUI HStack provides its own
        // background + border (matches the design's tinted glass row).
        field.isBordered = false
        field.isBezeled = false
        field.backgroundColor = .clear
        field.drawsBackground = false
        field.focusRingType = .none

        // One-line input. `usesSingleLineMode = true` is critical —
        // without it, even a single-line bordered field will wrap to
        // a second line if the text exceeds the visible width, which
        // is exactly the "two-line" rendering bug we kept hitting on
        // SwiftUI. Truncation on the head keeps the *end* of the key
        // visible — that's the part that varies, while the prefix
        // (`sk-proj-`) is shared by every project key.
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingHead
        field.maximumNumberOfLines = 1

        // Monospaced 11.5pt matches the previous SwiftUI design and
        // makes the masked-dot count read consistently regardless of
        // letter width.
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        field.font = font
        field.textColor = .labelColor

        // Custom muted placeholder so the hint reads as "приглушенный"
        // per the design spec — `NSTextField.placeholderString` uses
        // a near-white tint by default, which is too loud against the
        // dark row background.
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.32),
                .font: font,
            ]
        )

        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Only push when the binding drifted from the field — guards
        // against an update during typing clobbering the user's
        // cursor position.
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: AppKitSecretField

        init(_ parent: AppKitSecretField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        // AppKit fires Begin / End editing whenever first-responder
        // status changes on the field. We translate that to the
        // SwiftUI `isFocused` binding so the parent can pulse the
        // border without `@FocusState` (which has its own quirks
        // when wrapped in NSViewRepresentable).
        func controlTextDidBeginEditing(_ notification: Notification) {
            let parent = self.parent
            DispatchQueue.main.async {
                parent.isFocused = true
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            let parent = self.parent
            DispatchQueue.main.async {
                parent.isFocused = false
            }
        }
    }
}
