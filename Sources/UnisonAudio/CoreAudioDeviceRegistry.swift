import Foundation
import CoreAudio
import UnisonDomain

public final class CoreAudioDeviceRegistry: AudioDeviceRegistry, @unchecked Sendable {
    private var changesContinuation: AsyncStream<Void>.Continuation?
    public let deviceChanges: AsyncStream<Void>

    /// Extra fan-out callback for device-change events. Composition
    /// wires this so SettingsViewModel can refresh its device list
    /// when the user plugs in / unplugs hardware after the app
    /// launched. The orchestrator consumes `deviceChanges`
    /// (AsyncStream is single-subscriber); this callback exists so a
    /// second observer doesn't compete for the same events.
    /// Fires on the CoreAudio listener's main-thread dispatch.
    public var onDeviceListChanged: (@Sendable () -> Void)?

    public init() {
        var c: AsyncStream<Void>.Continuation!
        self.deviceChanges = AsyncStream { c = $0 }
        self.changesContinuation = c
        registerDeviceChangeListener()
    }

    deinit { unregisterDeviceChangeListener() }

    public func availableInputDevices() -> [AudioDevice] {
        allDevices().filter { hasStreams($0.audioObjectID, scope: kAudioObjectPropertyScopeInput) }
            .map { AudioDevice(uid: $0.uid, name: $0.name, kind: .input) }
    }

    public func availableOutputDevices() -> [AudioDevice] {
        allDevices().filter { hasStreams($0.audioObjectID, scope: kAudioObjectPropertyScopeOutput) }
            .map { AudioDevice(uid: $0.uid, name: $0.name, kind: .output) }
    }

    public func findBlackHole2ch() -> AudioDevice? {
        allDevices().first { $0.name.lowercased().contains("blackhole 2ch") }
            .map { AudioDevice(uid: $0.uid, name: $0.name, kind: .output) }
    }

    public func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return stringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    // MARK: - CoreAudio plumbing

    private struct RawDevice { let audioObjectID: AudioObjectID; let uid: String; let name: String }

    private func allDevices() -> [RawDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)

        return ids.compactMap { id in
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, selector: kAudioDevicePropertyDeviceNameCFString) else { return nil }
            return RawDevice(audioObjectID: id, uid: uid, name: name)
        }
    }

    private func stringProperty(_ id: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString?
        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return cfStr as String?
    }

    private func hasStreams(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return size > 0
    }

    private var listenerBlock: AudioObjectPropertyListenerBlock?

    private func registerDeviceChangeListener() {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.changesContinuation?.yield()
            self?.onDeviceListChanged?()
        }
        listenerBlock = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    private func unregisterDeviceChangeListener() {
        guard let block = listenerBlock else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }
}
