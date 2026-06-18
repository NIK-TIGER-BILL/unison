import SwiftUI

/// Clickable monospaced label that records a hotkey when active.
///
/// NSEvent monitors stay out of `UnisonUI`, so the actual monitor lives in
/// `UnisonApp/HotkeyService.swift`. This view renders the visual state and
/// exposes a binding (`isRecording`) plus a callback (`onCapture`) that
/// the host wires to a real local-event monitor.
///
/// The host implementation is expected to:
/// 1. Observe `isRecording` going `true`.
/// 2. Install a `NSEvent.addLocalMonitorForEvents(matching: .keyDown, …)`.
/// 3. Parse the event into a `Hotkey` via `HotkeyParser.parse(...)`.
/// 4. Call `onCapture(hotkey)` (or set `isRecording = false` on Esc).
public struct HotkeyRecorder: View {
    @Binding public var hotkey: Hotkey?
    @Binding public var isRecording: Bool
    public let onStartRecording: () -> Void

    public init(
        hotkey: Binding<Hotkey?>,
        isRecording: Binding<Bool>,
        onStartRecording: @escaping () -> Void
    ) {
        self._hotkey = hotkey
        self._isRecording = isRecording
        self.onStartRecording = onStartRecording
    }

    @SwiftUI.State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public var body: some View {
        let canPulse = isRecording && !reduceMotion
        return Button {
            // Toggle: clicking the chip mid-recording cancels (matches
            // the design). Without this the only exits were Esc or
            // closing the window — meanwhile the recording monitor
            // swallows all plain typing app-wide.
            if isRecording {
                isRecording = false
            } else {
                isRecording = true
                onStartRecording()
            }
        } label: {
            // HIG Materials: vibrant `.primary` while recording (the
            // pulsing chip is the focal point); `.secondary` while idle
            // so the chord reads as a quieter value.
            Text(label)
                .font(UnisonFonts.mono(11))
                .tracking(0.7)
                .foregroundStyle(isRecording ? .primary : .secondary)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .frame(minWidth: 60)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(UnisonColors.whiteAlpha(isRecording ? 0.14 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isRecording
                                ? UnisonColors.whiteAlpha(0.32)
                                : UnisonColors.whiteAlpha(0.10),
                            lineWidth: 0.5
                        )
                )
                .opacity(canPulse && pulsing ? 0.55 : 1.0)
                .animation(
                    canPulse
                        ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRecording ? "Запись горячей клавиши" : "Горячая клавиша: \(label)")
        .help(isRecording ? "Нажмите сочетание клавиш" : label)
        .onChange(of: isRecording) { _, new in
            pulsing = new && !reduceMotion
        }
    }

    private var label: String {
        if isRecording {
            return "нажмите…"
        }
        return hotkey?.display ?? "—"
    }
}
