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

    /// Translate bundle ID → AudioObjectID via CoreAudio. Returns nil if
    /// the process either is not running or has not produced audio yet.
    public static func processObjectID(forBundleID bundleID: String) -> AudioObjectID? {
        // Find the PID by matching bundle ID against running applications
        let processes = runningAudioProcesses()
        guard let process = processes.first(where: { $0.bundleID == bundleID }) else {
            return nil
        }
        return processObjectID(forPID: process.pid)
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
        return objIDs.compactMap(pidOfProcessObject)
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
