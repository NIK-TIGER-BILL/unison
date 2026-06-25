import CoreAudio
import Darwin
import Foundation
import UnisonDomain

/// One-shot helper for nudging macOS to display the TCC audio-capture
/// prompt. Used by onboarding when the user clicks "Разрешить".
///
/// macOS does not expose a public API to query the current
/// `kTCCServiceAudioCapture` status, so this function does not return
/// whether the user granted access. It runs a brief full ProcessTap
/// lifecycle (create + aggregate device + IOProc + start) to engage
/// TCC — `AudioHardwareCreateProcessTap` alone, or with an empty
/// exclusion list, returns success without prompting because TCC only
/// engages when the tap actually becomes operational via an
/// AggregateDevice + IOProcID + AudioDeviceStart chain.
public enum AudioCapturePermission {
    /// Triggers the macOS TCC `kTCCServiceAudioCapture` prompt by
    /// running a full ProcessTap lifecycle on a system-wide global
    /// tap, then immediately tearing it down.
    ///
    /// `async` because we need to wait for TCC to deliver the prompt
    /// (`AudioDeviceStart` returns immediately but the system prompt
    /// is dispatched asynchronously by `tccd`). The previous version
    /// blocked the calling thread with `Thread.sleep(forTimeInterval:)`,
    /// which froze the MainActor for 300 ms when onboarding called it.
    /// It also leaked the consumer Task — the new version holds the
    /// handle and cancels it explicitly before `stop()`.
    public static func triggerPrompt() async {
        let capture = ProcessTapCapture()
        let stream = capture.start()
        // Drain the stream so the IOProc start() lifecycle runs to
        // completion (create tap → aggregate device → IOProc →
        // AudioDeviceStart). The AudioDeviceStart call is what engages
        // TCC. We discard the frames; the side effect is what we want.
        let drain = Task.detached {
            for await _ in stream { /* discard */ }
        }
        // Give TCC time to deliver its prompt to the user. macOS's
        // prompt appears asynchronously after AudioDeviceStart returns;
        // 300 ms is empirically enough on this OS revision. We use
        // `Task.sleep` so we don't block the caller's thread.
        try? await Task.sleep(nanoseconds: 300_000_000)
        capture.stop()
        // Cancel the drain Task so it doesn't outlive the
        // `ProcessTapCapture` instance via the closure capture of
        // `stream`. `stop()` finishes the AsyncStream continuation,
        // so the loop would terminate on its own — but cancelling is
        // explicit and immediate.
        drain.cancel()
    }
}
