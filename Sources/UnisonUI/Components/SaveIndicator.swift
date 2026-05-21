import SwiftUI

/// Small "✓ сохранено" indicator. Designed to live in the Settings
/// title-bar (top-right). The parent flips `isShown` to `true` whenever
/// a setting is mutated; the indicator auto-fades back to invisible
/// after 1.6s via the embedded `triggerSave()` helper.
public struct SaveIndicator: View {
    @Binding public var isShown: Bool

    public init(isShown: Binding<Bool>) {
        self._isShown = isShown
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(UnisonColors.ready)
            // HIG Materials: vibrant `.secondary` so the indicator
            // reads as an unobtrusive status; the checkmark itself
            // stays the semantic `ready` green.
            Text("сохранено")
                .font(UnisonFonts.mono(10.5))
                .tracking(0.4)
                .foregroundStyle(.secondary)
        }
        .opacity(isShown ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: isShown)
    }
}

/// Helper view-model for `SaveIndicator`. Call `markSaved()` to flash the
/// indicator; it auto-hides after `displayDuration` seconds. Cancels any
/// in-flight timer so rapid mutations keep the indicator visible without
/// flicker.
@MainActor
@Observable
public final class SaveIndicatorController {
    public var isShown: Bool = false
    public let displayDuration: Double

    private var task: Task<Void, Never>?

    public init(displayDuration: Double = 1.6) {
        self.displayDuration = displayDuration
    }

    public func markSaved() {
        isShown = true
        task?.cancel()
        task = Task { [displayDuration] in
            try? await Task.sleep(nanoseconds: UInt64(displayDuration * 1_000_000_000))
            if !Task.isCancelled {
                self.isShown = false
            }
        }
    }
}

