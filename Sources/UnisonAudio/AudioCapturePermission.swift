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
    public static func triggerPrompt() {
        let capture = ProcessTapCapture(excludedBundleIDs: [])
        // Subscribe to the stream so the start() chain runs to completion
        // (create tap → aggregate device → IOProc → AudioDeviceStart). The
        // AudioDeviceStart call is what engages TCC.
        let stream = capture.start()
        // Drain the stream concurrently and discard frames — TCC engages
        // on AudioDeviceStart, not on frame consumption.
        Task.detached {
            for await _ in stream { /* discard */ }
        }
        // Give TCC time to deliver its prompt to the user. macOS's prompt
        // appears asynchronously after AudioDeviceStart returns.
        Thread.sleep(forTimeInterval: 0.3)
        capture.stop()
    }
}
