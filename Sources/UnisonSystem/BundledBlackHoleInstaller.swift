import Foundation
import CoreAudio
import UnisonDomain

public final class BundledBlackHoleInstaller: BlackHoleInstaller, @unchecked Sendable {
    private let twoChannelPkgName: String
    private let sixteenChannelPkgName: String
    private let bundle: Bundle

    public init(
        bundle: Bundle = .main,
        twoChannelPkgName: String = "BlackHole2ch",
        sixteenChannelPkgName: String = "BlackHole16ch"
    ) {
        self.bundle = bundle
        self.twoChannelPkgName = twoChannelPkgName
        self.sixteenChannelPkgName = sixteenChannelPkgName
    }

    public func is2chInstalled() -> Bool { hasDevice(named: "BlackHole 2ch") }
    public func is16chInstalled() -> Bool { hasDevice(named: "BlackHole 16ch") }

    public func runBundledInstaller() async throws {
        guard let pkg2 = bundle.url(forResource: twoChannelPkgName, withExtension: "pkg"),
              let pkg16 = bundle.url(forResource: sixteenChannelPkgName, withExtension: "pkg") else {
            throw NSError(domain: "BlackHoleInstaller", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Installer pkgs not bundled"])
        }

        let script = """
        do shell script "installer -pkg '\(pkg2.path)' -target /; installer -pkg '\(pkg16.path)' -target /" with administrator privileges
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            throw NSError(domain: "BlackHoleInstaller", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Installer failed"])
        }
    }

    private func hasDevice(named name: String) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return false }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        for id in ids {
            var nameAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var nameSize = UInt32(MemoryLayout<CFString?>.size)
            var cfStr: CFString?
            let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }
            if status == noErr, let s = cfStr as String?, s.lowercased() == name.lowercased() {
                return true
            }
        }
        return false
    }
}
