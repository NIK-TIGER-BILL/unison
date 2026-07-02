import Foundation
import Testing
@testable import UnisonAudio

// Bluetooth HFP protection. Field log (2026-07-02) caught the output route
// flipping to 16000 Hz × 1 ch mid-session — the Bluetooth HANDSFREE profile
// macOS forces whenever something opens the headset's mic. Narrowband HFP is
// the "sounds like they're behind a wall" symptom: everything the user hears
// (translation + original bed) collapses to ≤8–12 kHz bandwidth and gets
// quieter. Two defenses:
//  1. Detect a narrowband output route → surface a hint (user can pick a
//     different mic / accept the trade-off knowingly).
//  2. Don't CAUSE it: when the system-default input is the Bluetooth
//     headset's own mic, prefer the built-in mic instead (an explicit user
//     selection is always honored).

// MARK: - isNarrowbandRoute (output side)

@Test func narrowband_hfpRates_areDetected() {
    // The exact route from the field log: classic HFP (mSBC).
    #expect(AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 16_000, channels: 1))
    // CVSD legacy headsets.
    #expect(AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 8_000, channels: 1))
    // AirPods "wideband voice" (AAC-ELD 24 kHz) — still audibly muffled
    // next to A2DP; flag it too.
    #expect(AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 24_000, channels: 1))
    // LE Audio LC3 32 kHz voice route.
    #expect(AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 32_000, channels: 2))
}

@Test func narrowband_fullQualityRoutes_areNot() {
    #expect(!AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 44_100, channels: 2))  // A2DP
    #expect(!AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 48_000, channels: 2))  // speakers
    #expect(!AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 96_000, channels: 2))  // DAC
    // A mono-but-full-rate route (some USB speakers) is NOT narrowband.
    #expect(!AVAudioOutputMixer.isNarrowbandRoute(sampleRate: 48_000, channels: 1))
}

// MARK: - preferredMicUID (input side — don't trigger HFP)

private let btHeadset = CaptureDeviceInfo(uid: "bt-headset-mic", transportType: AVAudioEngineMicrophone.transportBluetooth)
private let builtIn = CaptureDeviceInfo(uid: "builtin-mic", transportType: AVAudioEngineMicrophone.transportBuiltIn)
private let usbMic = CaptureDeviceInfo(uid: "usb-mic", transportType: 0x7573_6220)  // 'usb '

@Test func micPolicy_bluetoothDefault_prefersBuiltIn() {
    // Opening the BT headset's mic forces the whole headset into HFP —
    // degrading the OUTPUT the user listens to. With a built-in mic
    // available, capture from it instead.
    let pick = AVAudioEngineMicrophone.preferredMicUID(
        systemDefault: btHeadset, available: [btHeadset, builtIn, usbMic])
    #expect(pick == "builtin-mic")
}

@Test func micPolicy_bluetoothLEDefault_prefersBuiltIn() {
    // LE-Audio headsets report the 'blea' transport, not classic 'blue' —
    // same voice-profile degradation, same policy.
    let bleHeadset = CaptureDeviceInfo(
        uid: "ble-headset-mic",
        transportType: AVAudioEngineMicrophone.transportBluetoothLE)
    let pick = AVAudioEngineMicrophone.preferredMicUID(
        systemDefault: bleHeadset, available: [bleHeadset, builtIn])
    #expect(pick == "builtin-mic")
}

@Test func micPolicy_bluetoothDefault_noBuiltIn_keepsDefault() {
    // Nothing better to offer (Mac mini + BT headset only) — keep the
    // default; the output-side hint still tells the user why it's muffled.
    let pick = AVAudioEngineMicrophone.preferredMicUID(
        systemDefault: btHeadset, available: [btHeadset, usbMic])
    #expect(pick == nil)
}

@Test func micPolicy_nonBluetoothDefault_untouched() {
    // Built-in or USB default: no HFP risk, never second-guess the system.
    #expect(AVAudioEngineMicrophone.preferredMicUID(
        systemDefault: builtIn, available: [builtIn, btHeadset]) == nil)
    #expect(AVAudioEngineMicrophone.preferredMicUID(
        systemDefault: usbMic, available: [usbMic, builtIn, btHeadset]) == nil)
}

@Test func micPolicy_noDefault_untouched() {
    #expect(AVAudioEngineMicrophone.preferredMicUID(
        systemDefault: nil, available: [builtIn]) == nil)
}
