import CoreAudio
import Darwin
import Foundation

/// One-shot helper for nudging macOS to display the TCC audio-capture
/// prompt. Used by onboarding when the user clicks "Разрешить".
///
/// macOS does not expose a public API to query the current
/// `kTCCServiceAudioCapture` status, so this function does not return
/// whether the user granted access. It returns once the throwaway tap
/// has been created (which is what triggers the prompt). The actual
/// verification of "granted vs denied" happens at first translation
/// Start via the silent-frame watchdog — see `SilentFrameWatchdog`.
public enum AudioCapturePermission {
    public static func triggerPrompt() {
        // Translate own PID to Audio Process Object.
        var pid = getpid()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var processObj: AudioObjectID = 0
        let translateStatus = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), pidPtr,
                &size, &processObj
            )
        }
        guard translateStatus == noErr, processObj != kAudioObjectUnknown else { return }

        // Create a tap on ourselves — this is what triggers the TCC prompt
        // for `kTCCServiceAudioCapture`. The tap is destroyed immediately.
        let desc = CATapDescription(monoMixdownOfProcesses: [processObj])
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        var tapID: AudioObjectID = 0
        _ = AudioHardwareCreateProcessTap(desc, &tapID)
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }
}
