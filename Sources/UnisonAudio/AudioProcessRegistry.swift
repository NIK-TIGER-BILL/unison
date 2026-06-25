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
    /// `bundleID`. Many apps emit audio from a helper/XPC process rather than
    /// the main one, and the helper's own bundle ID is no reliable guide —
    /// Yandex Music uses `ru.yandex.desktop.music.helper` (a child), but the
    /// Dia browser (`company.thebrowser.dia`) uses the shared
    /// `company.thebrowser.browser.helper` (a different subtree entirely).
    ///
    /// So instead of pattern-matching bundle IDs, we ask the system who is
    /// **responsible** for each audio process — the same app↔helper attribution
    /// macOS uses for TCC permissions and Activity Monitor's process grouping —
    /// and match that owning app's bundle ID. This is universal: it resolves
    /// any helper, XPC service, or renderer to its app without per-app rules.
    ///
    /// Falls back to executable-path containment in the app bundle only if the
    /// responsibility SPI is ever unavailable. Returns every match (an app may
    /// run several audio helpers).
    public static func audioObjectIDs(forBundleID bundleID: String) -> [AudioObjectID] {
        let appDir = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID)?
            .standardizedFileURL.path
        return audioProcessObjectList().filter { obj in
            guard let pid = pidOfProcessObject(obj) else { return false }
            if responsibleAppBundleID(ofPID: pid) == bundleID {
                return true
            }
            if let appDir, let exe = executablePath(ofPID: pid),
               isPath(exe, inside: appDir) {
                return true
            }
            return false
        }
    }

    /// The bundle ID of the application the system holds **responsible** for
    /// `pid` — i.e. the owning app of a helper/XPC process. Resolved via the
    /// `responsibility_get_pid_responsible_for_pid` SPI (looked up with
    /// `dlsym`, so a missing symbol degrades to nil rather than failing to
    /// link), then mapped to a bundle ID through the responsible PID.
    static func responsibleAppBundleID(ofPID pid: pid_t) -> String? {
        guard let resolve = responsibleForPID else { return nil }
        let responsible = resolve(pid)
        guard responsible > 0 else { return nil }
        return NSRunningApplication(processIdentifier: responsible)?.bundleIdentifier
    }

    /// Cached pointer to the responsibility SPI; nil if the symbol can't be
    /// found. A bare C function pointer carries no state, so it is safe to
    /// share across threads.
    private static let responsibleForPID: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

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
