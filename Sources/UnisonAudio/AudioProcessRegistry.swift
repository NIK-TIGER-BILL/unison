import AppKit
import CoreAudio
import Darwin
import Foundation

/// Describes one running process that has produced (or is producing)
/// audio at some point — what CoreAudio calls an Audio Process Object.
public struct AudioProcess: Sendable, Identifiable, Hashable {
    public var id: pid_t { pid }
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let bundlePath: String?
    public let isProducingAudio: Bool

    public init(pid: pid_t, bundleID: String, name: String,
                bundlePath: String?, isProducingAudio: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.isProducingAudio = isProducingAudio
    }
}

/// CoreAudio Process Object enumeration helpers.
///
/// macOS 14.2+ exposes per-process audio metadata via
/// `kAudioHardwarePropertyProcessObjectList`. Each Audio Process Object
/// has properties: PID, bundle ID, isRunning (= currently producing
/// audio). Project targets macOS 26, so no availability guards needed.
public enum AudioProcessRegistry {
    /// All audio process objects with resolved app metadata, sorted by
    /// display name. Apps that have not produced audio yet may not have
    /// an Audio Process Object — they appear here only after first
    /// audio activity.
    public static func runningAudioProcesses() -> [AudioProcess] {
        let pids = audioProcessPIDs()
        var processes: [AudioProcess] = []
        for pid in pids {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let bundleID = app.bundleIdentifier ?? "pid-\(pid)"
            let name = app.localizedName ?? bundleID
            let path = app.bundleURL?.path
            let producing = isProducingAudio(pid: pid)
            processes.append(AudioProcess(
                pid: pid, bundleID: bundleID, name: name,
                bundlePath: path, isProducingAudio: producing
            ))
        }
        return processes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// All audio process object IDs belonging to the app identified by
    /// `bundleID` — its own audio object plus any audio-producing **helper**
    /// processes. This is essential: many apps emit audio not from the main
    /// process but from a helper. Two cases, both handled:
    ///
    /// 1. Helper bundle ID is a dotted child of the app's, e.g. Yandex Music
    ///    plays through `ru.yandex.desktop.music.helper`.
    /// 2. Helper bundle ID lives in an unrelated subtree, e.g. the Dia browser
    ///    (`company.thebrowser.dia`) plays through `company.thebrowser.browser.helper`.
    ///    The link is on disk: the helper's executable sits **inside** the app
    ///    bundle (`/Applications/Dia.app/…/Browser Helper`).
    ///
    /// Without this, an excluded/included app's real audio stream is missed —
    /// the app is still tapped (blocklist) or, worse, an allowlist mixdown taps
    /// only the silent main process. Bundle IDs come from CoreAudio's own
    /// `kAudioProcessPropertyBundleID` (reports the helper's real identifier,
    /// unlike `NSRunningApplication`, which returns nil for helper PIDs).
    public static func audioObjectIDs(forBundleID bundleID: String) -> [AudioObjectID] {
        let appDir = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)?
            .standardizedFileURL.path
        return audioProcessObjectList().filter { obj in
            if let candidate = processBundleID(ofProcessObject: obj),
               bundleMatchesScope(candidate, target: bundleID) {
                return true
            }
            if let appDir,
               let pid = pidOfProcessObject(obj),
               let exe = executablePath(ofPID: pid),
               isPath(exe, inside: appDir) {
                return true
            }
            return false
        }
    }

    /// Whether an audio process's bundle ID `candidate` belongs to the app
    /// identified by `target`: an exact match, or a dotted child (`target.`)
    /// such as a `.helper`. The trailing dot prevents over-matching siblings
    /// that merely share a prefix (e.g. `…music` must not match `…musicbox`).
    static func bundleMatchesScope(_ candidate: String, target: String) -> Bool {
        candidate == target || candidate.hasPrefix(target + ".")
    }

    /// Whether `path` is the directory `dir` or lives inside it. Used to
    /// attribute a helper process to the app whose bundle contains its
    /// executable. The trailing-slash guard prevents `/…/Dia.app` from
    /// matching a sibling `/…/Diavolo.app`.
    static func isPath(_ path: String, inside dir: String) -> Bool {
        path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// Translate bundle ID → AudioObjectID via CoreAudio. Returns nil if the
    /// app (or a helper of it) is not currently producing audio. Convenience
    /// over `audioObjectIDs(forBundleID:)` when a single object suffices.
    public static func processObjectID(forBundleID bundleID: String) -> AudioObjectID? {
        audioObjectIDs(forBundleID: bundleID).first
    }

    /// Translate PID → AudioObjectID via CoreAudio. Returns nil if the
    /// PID has no Audio Process Object (i.e., process has never
    /// produced audio).
    public static func processObjectID(forPID pid: pid_t) -> AudioObjectID? {
        var pidVar = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var objID: AudioObjectID = 0
        let status = withUnsafeMutablePointer(to: &pidVar) { ptr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<pid_t>.size), ptr,
                &size, &objID
            )
        }
        return (status == noErr && objID != kAudioObjectUnknown) ? objID : nil
    }

    // MARK: - Private helpers

    private static func audioProcessPIDs() -> [pid_t] {
        audioProcessObjectList().compactMap(pidOfProcessObject)
    }

    /// Raw list of every CoreAudio Audio Process Object currently known.
    private static func audioProcessObjectList() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &addr, 0, nil, &size, &objIDs) == noErr else { return [] }
        return objIDs
    }

    /// CoreAudio's own bundle ID for an Audio Process Object. For helper
    /// processes this is the helper's identifier (e.g. `…music.helper`),
    /// which is exactly what we need to match against an app's bundle ID.
    private static func processBundleID(ofProcessObject obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cf: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &cf) { ptr in
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        let value = cf as String
        return value.isEmpty ? nil : value
    }

    /// Absolute path of a process's executable, or nil if it can't be read.
    private static func executablePath(ofPID pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard count > 0 else { return nil }
        return String(cString: buf)
    }

    private static func pidOfProcessObject(_ obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr,
              pid > 0 else { return nil }
        return pid
    }

    private static func isProducingAudio(pid: pid_t) -> Bool {
        guard let obj = processObjectID(forPID: pid) else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunning,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &running) == noErr else {
            return false
        }
        return running != 0
    }
}
