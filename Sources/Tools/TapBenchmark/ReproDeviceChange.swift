import AVFoundation
import CoreAudio
import Foundation
import UnisonAudio
import UnisonDomain

/// Reproduces the "connect BT headphones mid-session → no audio" bug WITHOUT
/// real Bluetooth. Connecting BT does exactly one thing CoreAudio-wise: it
/// changes the **default output device**, which makes `AVAudioEngine` post
/// `AVAudioEngineConfigurationChange` and stop its render graph. We trigger the
/// same event by flipping the default output device's nominal sample rate (or,
/// fallback, switching the default output device), then check whether the
/// production `AVAudioOutputMixer`'s engine stopped.
///
/// RESULT line:
///   "engine STOPPED" → bug reproduced (no self-heal)
///   "engine RUNNING" → fix present (self-healed) OR no change was triggered
///
/// Usage: repro-devicechange
enum ReproDeviceChange {
    static func mark(_ s: String) {
        FileHandle.standardError.write("[devrepro] \(s)\n".data(using: .utf8)!)
    }

    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        func bump() { lock.lock(); _count += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return _count }
    }

    @MainActor
    static func run() async {
        mark("=== device-change repro ===")
        let mixer = AVAudioOutputMixer()
        do { try await mixer.start(deviceUID: nil) } catch { mark("mixer.start FAILED \(error)"); return }
        mark("mixer.start.done isRunning=\(mixer.isEngineRunning)")

        let probe = Probe()
        let token = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { _ in
            probe.bump()
            mark("*** AVAudioEngineConfigurationChange ***")
        }
        defer { NotificationCenter.default.removeObserver(token) }

        // Feed a tone so the engine is actively rendering (matches production:
        // translated audio streaming through the player).
        var cont: AsyncStream<AudioFrame>.Continuation!
        let s = AsyncStream<AudioFrame>(bufferingPolicy: .bufferingOldest(8)) { cont = $0 }
        let feeder = Task { await mixer.playTranslated(s) }
        let yieldFrame = cont!
        let prod = ReproTeardown.toneProducer { yieldFrame.yield($0) }
        try? await Task.sleep(for: .seconds(1))
        mark("before change: isRunning=\(mixer.isEngineRunning)")

        let dev = defaultOutputDevice()
        logEnvironment(dev)

        // Trigger #1: flip the default output device's nominal sample rate.
        let restoreSR = flipSampleRate(dev)
        try? await Task.sleep(for: .seconds(2))
        mark("after SR-flip: isRunning=\(mixer.isEngineRunning) configChanges=\(probe.count)")

        // Trigger #2 (fallback): if no config change yet, switch the default
        // output device to another available output device.
        var restoreDev: AudioDeviceID = 0
        if probe.count == 0 {
            let others = outputDeviceIDs().filter { $0 != dev }
            if let other = others.first {
                mark("no config-change from SR-flip; switching default output \(dev) -> \(other)")
                restoreDev = dev
                setDefaultOutputDevice(other)
                try? await Task.sleep(for: .seconds(2))
                mark("after device-switch: isRunning=\(mixer.isEngineRunning) configChanges=\(probe.count)")
            } else {
                mark("no alternate output device available for the switch fallback")
            }
        }

        // Give any self-heal a moment, then verdict.
        try? await Task.sleep(for: .seconds(2))
        let running = mixer.isEngineRunning
        mark("FINAL: isRunning=\(running) configChanges=\(probe.count)")
        if probe.count == 0 {
            mark("RESULT: INCONCLUSIVE — no AVAudioEngineConfigurationChange was triggered in this environment")
        } else if running {
            mark("RESULT: engine RUNNING after \(probe.count) config-change(s) — self-healed (fix present)")
        } else {
            mark("RESULT: engine STOPPED after config-change — audio dead (BUG reproduced)")
        }

        // Best-effort restore.
        if restoreSR > 0 { setNominalSampleRate(dev, restoreSR) }
        if restoreDev != 0 { setDefaultOutputDevice(restoreDev) }
        prod.cancel(); feeder.cancel(); cont.finish()
    }

    // MARK: - CoreAudio helpers

    private static func defaultOutputDevice() -> AudioDeviceID {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0); var sz = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &sz, &dev)
        return dev
    }

    private static func setDefaultOutputDevice(_ dev: AudioDeviceID) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var d = dev
        let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &d)
        mark("setDefaultOutputDevice(\(dev)) status=\(st)")
    }

    private static func outputDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
        return ids.filter { hasOutputStreams($0) }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size)
        return size > 0
    }

    private static func nominalSampleRate(_ dev: AudioDeviceID) -> Float64 {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr: Float64 = 0; var sz = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &sz, &sr)
        return sr
    }

    private static func setNominalSampleRate(_ dev: AudioDeviceID, _ sr: Float64) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var target = sr
        let st = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float64>.size), &target)
        mark("setNominalSampleRate(\(dev), \(sr)) status=\(st)")
    }

    private static func availableSampleRates(_ dev: AudioDeviceID) -> [Float64] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(dev, &addr, 0, nil, &size)
        let n = Int(size) / MemoryLayout<AudioValueRange>.size
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: n)
        guard n > 0 else { return [] }
        AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &ranges)
        return ranges.map { $0.mMinimum }
    }

    /// Flip the device's nominal sample rate to a different available value.
    /// Returns the original rate (to restore), or 0 if nothing was changed.
    private static func flipSampleRate(_ dev: AudioDeviceID) -> Float64 {
        let current = nominalSampleRate(dev)
        let rates = availableSampleRates(dev)
        guard let target = rates.first(where: { abs($0 - current) > 1 }) else {
            mark("flipSampleRate: no alternative rate (available=\(rates), current=\(current))")
            return 0
        }
        mark("flipSampleRate: \(current) -> \(target)")
        setNominalSampleRate(dev, target)
        return current
    }

    private static func logEnvironment(_ dev: AudioDeviceID) {
        mark("default output dev=\(dev) currentSR=\(nominalSampleRate(dev)) availableSR=\(availableSampleRates(dev))")
        mark("output devices: \(outputDeviceIDs())")
    }
}
