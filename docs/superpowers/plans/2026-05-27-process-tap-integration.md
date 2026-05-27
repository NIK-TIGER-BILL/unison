# Process Tap Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace BlackHole 16ch inbound capture with CoreAudio Process Tap in production, with system-wide tap + user-configurable per-app exclusion list, and clean removal of all BH 16ch code/copy.

**Architecture:** One DI swap in `Composition.swift` (the existing `peerCapture: any PeerAudioCapture` abstraction) plus rework of `ProcessTapCapture` to use `monoGlobalTapButExcludeProcesses` + `mutedWhenTapped`. New `AudioProcessRegistry` utility. New Settings field. Onboarding "Audio setup" step gains an audio-capture sub-task. Silent-frame watchdog catches runtime TCC denial. BH 16ch code is deleted; BH 2ch outbound path stays.

**Tech Stack:** Swift 6.2, macOS 26 Tahoe, CoreAudio Process Tap (`CATapDescription`, `AudioHardwareCreateProcessTap`), CoreAudio Process Object API (`kAudioHardwarePropertyProcessObjectList`), Swift Testing, AppKit (`NSWorkspace`, `NSRunningApplication`).

**Source spec:** [docs/superpowers/specs/2026-05-27-process-tap-integration-design.md](../specs/2026-05-27-process-tap-integration-design.md)

---

## File Structure

**New files:**
- `Sources/UnisonAudio/AudioProcessRegistry.swift` — enumerate audio processes, resolve bundle ID → AudioObjectID
- `Sources/UnisonAudio/AudioCapturePermission.swift` — TCC prompt trigger (used by onboarding)
- `Sources/UnisonDomain/SilentFrameWatchdog.swift` — detect prolonged all-zero amplitude
- `Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift` — Settings UI
- `Sources/UnisonUI/Views/Settings/ExcludedAppsPicker.swift` — modal sheet
- `Tests/UnisonAudioTests/AudioProcessRegistryTests.swift`
- `Tests/UnisonDomainTests/SilentFrameWatchdogTests.swift`
- `Tests/UnisonDomainTests/SettingsTests.swift` (or add to existing if present)

**Modified files:**
- `Sources/UnisonAudio/ProcessTapCapture.swift` — new init signature, global tap, mutedWhenTapped
- `Sources/UnisonDomain/Settings.swift` — `excludedTapBundleIDs: [String]` field
- `Sources/UnisonDomain/Protocols/BlackHoleInstaller.swift` — drop `is16chInstalled()`
- `Sources/UnisonSystem/BundledBlackHoleInstaller.swift` — only install 2ch
- `Sources/UnisonUI/ViewModels/OnboardingViewModel.swift` — Audio setup sub-states + audio-capture probe action
- `Sources/UnisonUI/Views/Onboarding/OnboardingView.swift` (or wherever the .blackHole step is rendered) — sub-task rendering
- `Sources/UnisonApp/Composition.swift` — `peerCapture = ProcessTapCapture(...)`
- `Sources/UnisonDomain/TranslationOrchestrator.swift` — remove `blackHole16chMissing` guard + error case
- `Sources/UnisonAudio/CoreAudioDeviceRegistry.swift` — delete `findBlackHole16ch()`

**Deleted files:**
- `Sources/UnisonAudio/BlackHoleSinkCapture.swift`
- `Tests/UnisonAudioTests/BlackHoleSinkCaptureTests.swift` (if it exists)

**Docs/scripts to update:**
- `CLAUDE.md` — references to BH 16ch
- `scripts/VM_README.md` — if mentions 16ch
- `scripts/vm-screenshot.sh` / `scripts/vm-integration-test.sh` — if env vars or setup reference 16ch
- `README.md` — if mentions 16ch

---

## Conventions (read before starting)

- **Tests use Swift Testing** (`import Testing`, `@Test`, `#expect`), NOT XCTest. See `Tests/UnisonDomainTests/ClockTests.swift`.
- **Project targets macOS 26 Tahoe** — Process Tap (macOS 14.2+) and Process Object API (macOS 14.2+) are unconditionally available.
- **Russian UI copy** per the project's localization. Minimalist wording per memory note.
- **Logging** uses `UnisonLog(category:)` — see existing `BundledBlackHoleInstaller.log` for pattern.
- **DI** is in `Sources/UnisonApp/Composition.swift`.

---

## Task 1: `AudioProcessRegistry` — enumerate audio processes

**Files:**
- Create: `Sources/UnisonAudio/AudioProcessRegistry.swift`
- Create: `Tests/UnisonAudioTests/AudioProcessRegistryTests.swift`

Goal: utility that lists CoreAudio audio-producing processes with their bundle IDs and icons, and resolves bundle ID → AudioObjectID. Both `ProcessTapCapture` (for excluded-PIDs resolution) and the Excluded Apps picker need this.

- [ ] **Step 1: Create `AudioProcessRegistry.swift`**

```swift
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
        var bid = bundleID as CFString
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateBundleIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = UInt32(MemoryLayout<AudioObjectID>.size)
        var objID: AudioObjectID = 0
        let status = withUnsafeMutablePointer(to: &bid) { bidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                UInt32(MemoryLayout<CFString>.size), bidPtr,
                &size, &objID
            )
        }
        return (status == noErr && objID != kAudioObjectUnknown) ? objID : nil
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
```

- [ ] **Step 2: Write smoke test**

CoreAudio APIs cannot be fully mocked, so the test only verifies the registry returns a non-crashing result and the `AudioProcess` struct's value semantics. Create `Tests/UnisonAudioTests/AudioProcessRegistryTests.swift`:

```swift
import Testing
import Foundation
@testable import UnisonAudio

@Test func runningAudioProcesses_returnsAlphabeticallySorted() {
    let processes = AudioProcessRegistry.runningAudioProcesses()
    // Cannot assert non-empty (clean test runs may have no audio processes
    // yet), but if any are present they must be sorted.
    let names = processes.map(\.name)
    let sorted = names.sorted { $0.localizedCompare($1) == .orderedAscending }
    #expect(names == sorted)
}

@Test func audioProcess_isHashable() {
    let a = AudioProcess(pid: 1, bundleID: "x", name: "X", bundlePath: nil, isProducingAudio: false)
    let b = AudioProcess(pid: 1, bundleID: "x", name: "X", bundlePath: nil, isProducingAudio: false)
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
}

@Test func processObjectID_unknownBundleReturnsNil() {
    let result = AudioProcessRegistry.processObjectID(forBundleID: "com.nonexistent.bundle.does.not.exist")
    #expect(result == nil)
}
```

- [ ] **Step 3: Verify build + tests pass**

Run: `swift build && swift test --filter AudioProcessRegistryTests`

Expected: 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/UnisonAudio/AudioProcessRegistry.swift Tests/UnisonAudioTests/AudioProcessRegistryTests.swift
git commit -m "feat(unison-audio): AudioProcessRegistry — list audio processes, resolve bundle IDs"
```

---

## Task 2: Rework `ProcessTapCapture` for global tap + mutedWhenTapped

**Files:**
- Modify: `Sources/UnisonAudio/ProcessTapCapture.swift`
- Create: `Sources/UnisonAudio/AudioCapturePermission.swift`

Goal: change the public API from `init(targetPID:)` to `init(excludedBundleIDs:)`, switch to `CATapDescription(monoGlobalTapButExcludeProcesses:)` and `muteBehavior = .mutedWhenTapped`. Add a static helper for triggering TCC prompt (used in onboarding next task).

- [ ] **Step 1: Modify `ProcessTapCapture.swift`**

Replace the existing `targetPID`-based initialization. Open `Sources/UnisonAudio/ProcessTapCapture.swift` and update the relevant sections.

Replace the property `public let targetPID: pid_t` and `private var processObjectID` with:

```swift
public let excludedBundleIDs: [String]
private var processObjectIDs: [AudioObjectID] = []  // resolved at start()
```

Replace the init:

```swift
public init(excludedBundleIDs: [String] = []) {
    self.excludedBundleIDs = excludedBundleIDs
}
```

Replace `resolveProcessObject()` with:

```swift
private func resolveExcludedProcessObjects() {
    var ids: [AudioObjectID] = []
    // Always exclude ourselves to avoid feedback.
    if let own = AudioProcessRegistry.processObjectID(forPID: getpid()) {
        ids.append(own)
    }
    // Resolve each excluded bundle ID via AudioProcessRegistry. Apps
    // that aren't running OR haven't produced audio yet won't have an
    // Audio Process Object — silently skip them; they can't appear in
    // the system tap anyway.
    for bundleID in excludedBundleIDs {
        if let obj = AudioProcessRegistry.processObjectID(forBundleID: bundleID) {
            ids.append(obj)
        }
    }
    processObjectIDs = ids
}
```

Replace `createTap()`:

```swift
private func createTap() throws {
    let desc = CATapDescription(
        monoGlobalTapButExcludeProcesses: processObjectIDs
    )
    desc.isPrivate = true
    desc.muteBehavior = .mutedWhenTapped
    let status = AudioHardwareCreateProcessTap(desc, &tapObjectID)
    try check(status, "AudioHardwareCreateProcessTap")
    guard tapObjectID != kAudioObjectUnknown else {
        throw ProcessTapError.tapCreationFailed
    }
}
```

Update the `start()` chain to call `resolveExcludedProcessObjects()` instead of `resolveProcessObject()`:

```swift
public func start() -> AsyncStream<AudioFrame> {
    if started { stop() }
    return AsyncStream { [weak self] c in
        guard let self else { c.finish(); return }
        self.continuation = c
        do {
            self.resolveExcludedProcessObjects()
            try self.createTap()
            try self.createAggregateDevice()
            try self.queryNativeSampleRate()
            try self.installIOProc()
            try self.startDevice()
            self.started = true
        } catch {
            c.finish()
            self.teardown()
        }
    }
}
```

Drop the `processNotFound` error case from `ProcessTapError` (no single PID to fail on now):

```swift
public enum ProcessTapError: Error, CustomStringConvertible {
    case tapCreationFailed
    case aggregateCreationFailed
    case ioProcMissing
    case coreAudio(call: String, status: OSStatus, fourCC: String)

    public var description: String {
        switch self {
        case .tapCreationFailed:       return "ProcessTap: tap creation returned no object"
        case .aggregateCreationFailed: return "ProcessTap: aggregate creation returned no object"
        case .ioProcMissing:           return "ProcessTap: IOProc not installed"
        case .coreAudio(let call, let status, let fourCC):
            return "ProcessTap: \(call) failed with status \(status) ('\(fourCC)')"
        }
    }
}
```

Also update the `teardown()` to not reference `processObjectID` (which no longer exists):

```swift
private func teardown() {
    if let procID = ioProcID, aggregateDeviceID != 0 {
        AudioDeviceStop(aggregateDeviceID, procID)
        AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
    }
    ioProcID = nil
    if aggregateDeviceID != 0 {
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        aggregateDeviceID = 0
    }
    if tapObjectID != 0 {
        AudioHardwareDestroyProcessTap(tapObjectID)
        tapObjectID = 0
    }
    processObjectIDs.removeAll()
}
```

- [ ] **Step 2: Create `AudioCapturePermission.swift`**

This helper triggers the macOS TCC audio-capture prompt by creating + immediately destroying a Process Tap on ourselves. macOS has no public API to query the current `kTCCServiceAudioCapture` status, so the function returns void — the caller assumes the user is presented with the prompt.

Create `Sources/UnisonAudio/AudioCapturePermission.swift`:

```swift
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
```

- [ ] **Step 3: Verify build**

Run: `swift build`

Expected: clean, no errors.

The existing `ProcessTapCaptureTests` (if any) will fail because the public API changed. Update them if they exist; if not, smoke is sufficient since CoreAudio APIs can't be unit-tested.

- [ ] **Step 4: Commit**

```bash
git add Sources/UnisonAudio/ProcessTapCapture.swift Sources/UnisonAudio/AudioCapturePermission.swift
git commit -m "feat(unison-audio): ProcessTapCapture global tap + mutedWhenTapped, AudioCapturePermission helper"
```

---

## Task 3: `Settings.excludedTapBundleIDs` field

**Files:**
- Modify: `Sources/UnisonDomain/Settings.swift`
- Create or Modify: `Tests/UnisonDomainTests/SettingsTests.swift`

Goal: add a `[String]` field for user-excluded bundle IDs, with Codable round-trip.

- [ ] **Step 1: Write failing test**

Create `Tests/UnisonDomainTests/SettingsTests.swift` (or extend existing if present):

```swift
import Testing
import Foundation
@testable import UnisonDomain

@Test func settings_excludedTapBundleIDs_defaultsToEmpty() {
    let s = Settings()
    #expect(s.excludedTapBundleIDs.isEmpty)
}

@Test func settings_excludedTapBundleIDs_codableRoundTrip() throws {
    var s = Settings()
    s.excludedTapBundleIDs = ["com.spotify.client", "com.apple.Music"]
    let data = try JSONEncoder().encode(s)
    let decoded = try JSONDecoder().decode(Settings.self, from: data)
    #expect(decoded.excludedTapBundleIDs == ["com.spotify.client", "com.apple.Music"])
}

@Test func settings_excludedTapBundleIDs_codableRoundTrip_missingFieldDecodesEmpty() throws {
    // Settings persisted before this field existed must decode to an empty array.
    let legacyJSON = """
    {
        "sessionMode": "call",
        "languagePair": { "mine": "ru", "theirs": "en" },
        "originalMixVolume": 0.2
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Settings.self, from: legacyJSON)
    #expect(decoded.excludedTapBundleIDs.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter SettingsTests`

Expected: compile error (`excludedTapBundleIDs` not defined).

- [ ] **Step 3: Add the field to `Settings.swift`**

Modify `Sources/UnisonDomain/Settings.swift`:

```swift
public struct Settings: Equatable, Codable, Sendable {
    public var sessionMode: SessionMode
    public var languagePair: LanguagePair
    public var inputDeviceUID: String?
    public var outputDeviceUID: String?
    public var excludedTapBundleIDs: [String]
    private var _originalMixVolume: Float

    public var originalMixVolume: Float {
        get { _originalMixVolume }
        set { _originalMixVolume = min(max(newValue, 0.0), 1.0) }
    }

    public init(
        sessionMode: SessionMode = .call,
        languagePair: LanguagePair = .default,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        excludedTapBundleIDs: [String] = [],
        originalMixVolume: Float = 0.2
    ) {
        self.sessionMode = sessionMode
        self.languagePair = languagePair
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.excludedTapBundleIDs = excludedTapBundleIDs
        self._originalMixVolume = min(max(originalMixVolume, 0.0), 1.0)
    }

    public static let `default` = Settings()

    private enum CodingKeys: String, CodingKey {
        case sessionMode, languagePair, inputDeviceUID, outputDeviceUID
        case excludedTapBundleIDs
        case _originalMixVolume = "originalMixVolume"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionMode = try c.decode(SessionMode.self, forKey: .sessionMode)
        self.languagePair = try c.decode(LanguagePair.self, forKey: .languagePair)
        self.inputDeviceUID = try c.decodeIfPresent(String.self, forKey: .inputDeviceUID)
        self.outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        self.excludedTapBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .excludedTapBundleIDs) ?? []
        let raw = try c.decode(Float.self, forKey: ._originalMixVolume)
        self._originalMixVolume = min(max(raw, 0.0), 1.0)
    }
}
```

Note: explicit `init(from:)` is added so the new field decodes as empty when missing from persisted JSON. Without it, the auto-synthesized decoder would fail on legacy Settings JSON.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SettingsTests`

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/Settings.swift Tests/UnisonDomainTests/SettingsTests.swift
git commit -m "feat(unison-domain): Settings.excludedTapBundleIDs with backward-compatible decoding"
```

---

## Task 4: `BundledBlackHoleInstaller` — install only BlackHole 2ch

**Files:**
- Modify: `Sources/UnisonSystem/BundledBlackHoleInstaller.swift`
- Modify: `Sources/UnisonDomain/Protocols/BlackHoleInstaller.swift`
- Modify: `Tests/UnisonSystemTests/BundledBlackHoleInstallerTests.swift`

Goal: strip the 16ch download/install from the flow. The protocol's `is16chInstalled()` method is removed (cascades to OnboardingViewModel in next task).

- [ ] **Step 1: Update `BlackHoleInstaller.swift` protocol**

Modify `Sources/UnisonDomain/Protocols/BlackHoleInstaller.swift`. Delete `is16chInstalled()` from the protocol. The exact contents depend on what's there; the result should look like:

```swift
public protocol BlackHoleInstaller: Sendable {
    func is2chInstalled() -> Bool
    /// Downloads and installs BlackHole 2ch. The implementation MUST verify
    /// that the 2ch device appears in CoreAudio before returning success —
    /// after `installer(8)` exits, re-check `is2chInstalled()` (which reads
    /// CoreAudio's device list) and throw `verificationFailed` if it stays
    /// false.
    func runBundledInstaller() async throws
}
```

(Adjust to match existing doc-comment style; delete the `is16chInstalled` line entirely, do not preserve a stub.)

- [ ] **Step 2: Update `BundledBlackHoleInstaller.swift`**

Open `Sources/UnisonSystem/BundledBlackHoleInstaller.swift`. Delete the line declaring `is16chInstalled()`:

```swift
public func is16chInstalled() -> Bool { hasDevice(named: "BlackHole 16ch") }
```

Find the 16ch download/install logic inside `runBundledInstaller()`. The current code iterates over both 2ch and 16ch assets. Change it to handle only 2ch.

Locate the section that filters release assets (around finding `BlackHole2ch.v…pkg` and `BlackHole16ch.v…pkg`). Drop the 16ch filtering. The verifier loop that reads `installed = is2chInstalled() && is16chInstalled()` becomes just `installed = is2chInstalled()` — find and update it.

Concrete location reference (from current `BundledBlackHoleInstaller.swift`):

- Delete `public func is16chInstalled() -> Bool { hasDevice(named: "BlackHole 16ch") }` (was line 121)
- Find the loop that polls until `is2chInstalled() && is16chInstalled()` (was line ~403) and remove the `&& is16chInstalled()`
- In the asset-selection logic that picks `.pkg` URLs to download — remove the 16ch entry from the list. The 2ch entry is kept.

The exact code shape depends on how the implementer wrote the asset matcher (it's around lines 130-220 of the current file). The implementer's job is to:
- Identify the 16ch asset URL filter (likely `"BlackHole16ch"` or `"16ch"` substring match)
- Delete that filter and any subsequent download/install for it
- Keep ALL the 2ch logic intact

- [ ] **Step 3: Update `BundledBlackHoleInstallerTests.swift`**

Open `Tests/UnisonSystemTests/BundledBlackHoleInstallerTests.swift`. Find tests that reference `is16chInstalled` or 16ch assets. Update them to only check 2ch. Delete tests that exclusively exercise the 16ch path (they're redundant after the cleanup).

Specific edits:
- Any test asserting `installer.is16chInstalled() == true/false` → delete that assertion
- Any fixture JSON that includes a `BlackHole16ch.v0.6.x.pkg` asset URL → leave it in the fixture (releases on GitHub still have both), but update the test expectation: the installer should only download the 2ch one
- Tests for `verificationFailed` should now flip the verifier closure to return `is2chInstalled()` only

- [ ] **Step 4: Run installer tests**

Run: `swift test --filter BundledBlackHoleInstaller`

Expected: all tests pass. Test count may decrease by 1-2 if exclusively-16ch tests were deleted.

- [ ] **Step 5: Verify full build**

Run: `swift build`

Expected: clean. If `OnboardingViewModel` still references `is16chInstalled()` (it will — task 5 fixes that), the build will fail. Note this in your report — the next task addresses it.

If build fails ONLY due to `OnboardingViewModel.is16chInstalled` call sites, that's expected and resolves in Task 5. Commit task 4 as-is even with broken build at this point (transitional state is normal during multi-task refactors); the cascading fix is the very next task.

If build fails for other reasons — STOP and report.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonSystem/BundledBlackHoleInstaller.swift \
        Sources/UnisonDomain/Protocols/BlackHoleInstaller.swift \
        Tests/UnisonSystemTests/BundledBlackHoleInstallerTests.swift
git commit -m "refactor(unison-system): BlackHole installer drops 16ch (BH 16ch no longer used)"
```

---

## Task 5: `OnboardingViewModel` — Audio setup with two sub-tasks

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/OnboardingViewModel.swift`
- Modify: `Tests/UnisonDomainTests/OnboardingViewModelTests.swift`

Goal: the `.blackHole` step becomes "Audio setup" with TWO sub-tasks: install BH 2ch + grant audio capture. Both must be ✓ for the step to complete.

- [ ] **Step 1: Add audio capture state to ViewModel**

Open `Sources/UnisonUI/ViewModels/OnboardingViewModel.swift`. Add a new observed property tracking the audio capture sub-task. The existing `status[.blackHole]` becomes the OVERALL step status; it is `.done` iff both sub-states are done.

Add near the existing `status` property:

```swift
/// Sub-state for the "Allow audio capture" sub-task inside the
/// `.blackHole` (Audio setup) step. Tracked separately from
/// `status[.blackHole]` because the overall step requires BOTH the
/// BlackHole 2ch install AND audio capture grant.
public private(set) var audioCaptureStatus: OnboardingStepStatus = .pending

/// Sub-state for the BlackHole 2ch install sub-task. Same rationale.
public private(set) var blackHoleInstallStatus: OnboardingStepStatus = .pending
```

- [ ] **Step 2: Update `refresh()` to derive `.blackHole` status from sub-states**

Replace the old:

```swift
let bhDone = installer.is2chInstalled() && installer.is16chInstalled()
```

with:

```swift
let bh2chDone = installer.is2chInstalled()
// Audio capture grant is not queryable via public API. We only know
// the user clicked through onboarding by reading our own state.
let audioCaptureDone = audioCaptureStatus.isDone
let bhDone = bh2chDone && audioCaptureDone
```

Also: if `installer.is2chInstalled()` is true, update `blackHoleInstallStatus` to `.done` in the refresh logic (so users who already have 2ch from a previous version see the install sub-task pre-satisfied):

```swift
if bh2chDone {
    blackHoleInstallStatus = .done
} else if case .inProgress = blackHoleInstallStatus {
    // leave it
} else if case .error = blackHoleInstallStatus {
    // preserve error
} else {
    blackHoleInstallStatus = .pending
}
```

Put this block inside `refresh()` right after computing `bh2chDone`.

- [ ] **Step 3: Split `installBlackHole()` into a 2ch-only action**

Replace the existing `installBlackHole()` function. The new function uses `blackHoleInstallStatus` instead of `status[.blackHole]`:

```swift
public func installBlackHole() async {
    blackHoleInstallStatus = .inProgress
    refreshOverallBlackHoleStatus()
    do {
        try await installer.runBundledInstaller()
        if installer.is2chInstalled() {
            blackHoleInstallStatus = .done
        } else {
            blackHoleInstallStatus = .error(
                "Установка завершилась, но BlackHole 2ch не появился среди аудиоустройств."
            )
        }
    } catch let error as BlackHoleInstallError {
        switch error {
        case .verificationFailed:
            blackHoleInstallStatus = .error(
                "BlackHole 2ch не появился среди аудиоустройств. Перезапустите Unison или установите вручную."
            )
        case .installFailed(let detail):
            let lower = detail.lowercased()
            if lower.contains("canceled") || lower.contains("cancelled") || lower.contains("отмен") {
                blackHoleInstallStatus = .error(
                    "Установка отменена. Введите пароль администратора, чтобы установить BlackHole 2ch."
                )
            } else {
                blackHoleInstallStatus = .error(
                    "Не удалось установить BlackHole. Подробности в Console.app (subsystem com.unison.app)."
                )
            }
        case .downloadFailed:
            blackHoleInstallStatus = .error(
                "Не удалось скачать BlackHole. Проверьте подключение к интернету."
            )
        case .releaseFetchFailed:
            blackHoleInstallStatus = .error(
                "Не удалось получить информацию о последнем релизе BlackHole с GitHub."
            )
        case .signatureInvalid:
            blackHoleInstallStatus = .error(
                "Подпись пакета BlackHole не прошла проверку."
            )
        case .assetsNotFound:
            blackHoleInstallStatus = .error(
                "Не удалось найти пакет BlackHole 2ch для последнего релиза."
            )
        }
    } catch {
        blackHoleInstallStatus = .error(
            "Не удалось установить BlackHole. Подробности в Console.app (subsystem com.unison.app)."
        )
    }
    refresh()
}

/// Recomputes overall `status[.blackHole]` from the two sub-states.
private func refreshOverallBlackHoleStatus() {
    let install = blackHoleInstallStatus
    let capture = audioCaptureStatus
    if install.isDone && capture.isDone {
        status[.blackHole] = .done
    } else if case .error(let m) = install {
        status[.blackHole] = .error(m)
    } else if case .error(let m) = capture {
        status[.blackHole] = .error(m)
    } else if install.isInProgress || capture.isInProgress {
        status[.blackHole] = .inProgress
    } else {
        status[.blackHole] = .pending
    }
}
```

- [ ] **Step 4: Add the audio capture request action**

`UnisonUI` already imports `UnisonAudio` indirectly through `UnisonDomain`; add the direct import at the top of the file if needed:

```swift
import UnisonAudio
```

Then add the new action:

```swift
/// Triggers the macOS TCC audio-capture prompt by creating + immediately
/// destroying a throwaway Process Tap. macOS does not expose a public API
/// to query the resulting permission state, so this method optimistically
/// marks the sub-task as `.done` once the prompt has been dismissed. The
/// actual "translation gets silent buffers" case is caught at runtime by
/// the silent-frame watchdog and surfaces a banner with a System Settings
/// deep link.
public func requestAudioCapturePermission() async {
    audioCaptureStatus = .inProgress
    refreshOverallBlackHoleStatus()
    AudioCapturePermission.triggerPrompt()
    // Give macOS time to display the prompt and the user time to respond.
    // We can't tell grant vs deny, so we optimistically mark complete.
    try? await Task.sleep(nanoseconds: 300_000_000)
    audioCaptureStatus = .done
    refresh()
}
```

- [ ] **Step 5: Update existing tests + add new ones**

Open `Tests/UnisonDomainTests/OnboardingViewModelTests.swift`. Find existing tests asserting `installer.is16chInstalled()` — delete those assertions. Find tests asserting `status[.blackHole] == .done` after `installBlackHole()` succeeds — update them to also set `audioCaptureStatus = .done` first (or to assert `blackHoleInstallStatus == .done` instead of the overall status).

Add three new tests:

```swift
@Test func onboarding_audioSetup_requiresBothSubTasks() async {
    let vm = OnboardingViewModel(
        permissions: MockPermissions(),
        installer: MockInstaller(is2chInstalled: { true }),
        keychain: MockKeychain()
    )
    vm.refresh()
    // 2ch is installed → install sub-task is done. But audio capture is not granted yet.
    #expect(vm.blackHoleInstallStatus == .done)
    #expect(vm.audioCaptureStatus == .pending)
    #expect(vm.status[.blackHole] == .pending)
}

@Test func onboarding_audioSetup_bothSubTasksDone_overallDone() async {
    let vm = OnboardingViewModel(
        permissions: MockPermissions(),
        installer: MockInstaller(is2chInstalled: { true }),
        keychain: MockKeychain()
    )
    vm.refresh()
    await vm.requestAudioCapturePermission()
    #expect(vm.audioCaptureStatus == .done)
    #expect(vm.status[.blackHole] == .done)
}

@Test func onboarding_audioSetup_installError_propagatesToOverall() async {
    let vm = OnboardingViewModel(
        permissions: MockPermissions(),
        installer: MockInstaller(
            is2chInstalled: { false },
            runBundledInstaller: { throw BlackHoleInstallError.downloadFailed }
        ),
        keychain: MockKeychain()
    )
    await vm.installBlackHole()
    #expect(vm.blackHoleInstallStatus.errorMessage != nil)
    #expect(vm.status[.blackHole].errorMessage != nil)
}
```

(If existing `MockInstaller` doesn't accept closures for `runBundledInstaller`, update it. The pattern matches the existing test fixture conventions.)

- [ ] **Step 6: Verify build + tests**

Run: `swift build && swift test --filter OnboardingViewModelTests`

Expected: all tests pass. The codebase compiles end-to-end now (the `is16chInstalled` cascade from Task 4 is resolved).

- [ ] **Step 7: Commit**

```bash
git add Sources/UnisonUI/ViewModels/OnboardingViewModel.swift \
        Tests/UnisonDomainTests/OnboardingViewModelTests.swift
git commit -m "feat(onboarding): Audio setup step with install + audio capture sub-tasks"
```

---

## Task 6: Onboarding View — render new sub-tasks

**Files:**
- Modify: `Sources/UnisonUI/Views/Onboarding/OnboardingView.swift` (or wherever the .blackHole step is rendered — find it via grep)

Goal: the UI for the `.blackHole` step now renders two rows (Install + Allow audio capture) instead of one. Wording follows the minimalist preference per the project's UX note.

- [ ] **Step 1: Locate the .blackHole step rendering**

Run: `grep -rn "OnboardingStepKind.blackHole\|case .blackHole" Sources/UnisonUI/Views/`

Identify the view (or sub-view) that renders the BlackHole card. There is likely a `BlackHoleStep` (or similarly named) SwiftUI view, OR it is rendered inline inside `OnboardingView` via a switch on `OnboardingStepKind`.

- [ ] **Step 2: Rewrite the BlackHole step card to two sub-rows**

Replace the existing single-row install card with a card containing two rows. Use the existing card / row styling from neighbouring views (microphone, apiKey) for visual consistency.

Pseudo-structure (adapt to existing component types in the codebase):

```swift
// Inside the view body where .blackHole is rendered:
VStack(alignment: .leading, spacing: 12) {
    Text("Аудио")
        .font(.headline)

    // Sub-task 1: BlackHole 2ch
    HStack {
        statusIcon(for: vm.blackHoleInstallStatus)
        Text("Виртуальный микрофон (BlackHole 2ch)")
        Spacer()
        if !vm.blackHoleInstallStatus.isDone {
            Button("Установить") {
                Task { await vm.installBlackHole() }
            }
            .disabled(vm.blackHoleInstallStatus.isInProgress)
        }
    }
    if let msg = vm.blackHoleInstallStatus.errorMessage {
        ErrorRow(message: msg)
    }

    // Sub-task 2: Audio capture
    HStack {
        statusIcon(for: vm.audioCaptureStatus)
        Text("Захват системного звука")
        Spacer()
        if !vm.audioCaptureStatus.isDone {
            Button("Разрешить") {
                Task { await vm.requestAudioCapturePermission() }
            }
            .disabled(vm.audioCaptureStatus.isInProgress)
        }
    }
    if let msg = vm.audioCaptureStatus.errorMessage {
        ErrorRow(message: msg)
    }
}
```

Where `statusIcon(for:)` returns the appropriate ✓/spinner/✗ glyph already used elsewhere in onboarding, and `ErrorRow` is the existing project component. If those component helpers have different names in this codebase, substitute the existing equivalents.

Important: this UI rework is mostly mechanical wiring; the implementer must read the existing onboarding card style and match it. Do not invent new visual primitives.

- [ ] **Step 3: Drop "Установить вручную ↗" link wording if it references both 2ch and 16ch**

Find the manual-install escape-hatch link (currently `OnboardingViewModel.blackHoleManualInstallURL`). Make sure any surrounding UI text mentions only "BlackHole 2ch" (not "BlackHole 16ch and 2ch").

- [ ] **Step 4: Verify build + UI snapshot tests**

Run: `swift build && swift test --filter OnboardingViewSnapshotTests` (if such tests exist; check `Tests/UnisonUITests/`).

Expected: build clean. Snapshot tests may need a refreshed reference image — that is acceptable; rerun with the appropriate snapshot regeneration flag if applicable.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/Views/Onboarding/  # or whichever path the file is in
git commit -m "feat(onboarding): two-row Audio setup step (install 2ch + allow capture)"
```

---

## Task 7: `Composition.swift` swap + `TranslationOrchestrator` guard removal

**Files:**
- Modify: `Sources/UnisonApp/Composition.swift`
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`

Goal: wire `ProcessTapCapture` as `peerCapture`; remove the now-obsolete `blackHole16chMissing` guard in `Orchestrator.start()`.

- [ ] **Step 1: Update `Composition.swift`**

Find the line that creates the peer capture. From the earlier exploration:

```swift
let peerCap = BlackHoleSinkCapture(registry: registry)
```

Replace with:

```swift
let peerCap = ProcessTapCapture(excludedBundleIDs: settings.excludedTapBundleIDs)
```

`settings` is already in scope — `Composition` reads it for other DI wiring (input/output device UIDs etc.). If the variable name differs (`appSettings`, `currentSettings`, etc.), use the existing one.

- [ ] **Step 2: Remove the BH 16ch guard in `TranslationOrchestrator.start()`**

Open `Sources/UnisonDomain/TranslationOrchestrator.swift`. Delete the block at line 164-170 (numbering may have shifted slightly):

```swift
if mode == .call || mode == .listen {
    guard deviceRegistry.findBlackHole16ch() != nil else {
        Self.log.error("start() guard failed: BlackHole 16ch not found → .error(.blackHole16chMissing)")
        state = .error(.blackHole16chMissing)
        return
    }
}
```

Delete the `case blackHole16chMissing` from the `TranslationError` enum (or whatever enum holds it — likely in the same file or `Sources/UnisonDomain/TranslationError.swift`). Find and delete it:

```swift
case blackHole16chMissing  // delete this case
```

And delete any case in a `localizedDescription` / `switch` over the error enum that references `.blackHole16chMissing`. Use grep:

```bash
grep -rn "blackHole16chMissing" Sources/ Tests/
```

Every match must be removed (case definition + use sites in switches).

- [ ] **Step 3: Verify build + tests**

Run: `swift build && swift test`

Expected: builds clean, tests pass. The orchestrator now creates a Process Tap-backed `peerCapture` and no longer requires BH 16ch at runtime.

- [ ] **Step 4: Commit**

```bash
git add Sources/UnisonApp/Composition.swift Sources/UnisonDomain/TranslationOrchestrator.swift
git commit -m "feat(orchestrator): peerCapture = ProcessTapCapture; drop BH 16ch guard"
```

---

## Task 8: `SilentFrameWatchdog` — catch TCC denial at runtime

**Files:**
- Create: `Sources/UnisonDomain/SilentFrameWatchdog.swift`
- Create: `Tests/UnisonDomainTests/SilentFrameWatchdogTests.swift`
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift`

Goal: if 10 s elapse with all-zero amplitude on the peer audio stream while a session is active, flip state to `.error` with a TCC-denied banner. Production safety net for the case where TCC was revoked between sessions or never granted.

- [ ] **Step 1: Write failing tests**

Create `Tests/UnisonDomainTests/SilentFrameWatchdogTests.swift`:

```swift
import Testing
import Foundation
@testable import UnisonDomain

@Test func watchdog_silenceForFullThreshold_triggersError() async {
    var triggered = false
    let watchdog = SilentFrameWatchdog(thresholdSeconds: 0.05) {
        triggered = true
    }
    watchdog.start()
    // Feed 100 ms of all-zero samples.
    let zeros = Data(repeating: 0, count: 4 * 1000)  // 1000 Float32 zeros
    for _ in 0..<10 {
        watchdog.observe(zeros)
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    watchdog.stop()
    #expect(triggered)
}

@Test func watchdog_nonZeroSampleResetsTimer() async {
    var triggered = false
    let watchdog = SilentFrameWatchdog(thresholdSeconds: 0.1) {
        triggered = true
    }
    watchdog.start()
    let zeros = Data(repeating: 0, count: 4 * 100)
    var nonZero = Data(count: 4 * 100)
    nonZero.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: Float.self).baseAddress!
        p[0] = 0.5
    }
    // 50 ms zeros, then a non-zero, then 50 ms zeros — should NOT trigger
    // because the non-zero resets the timer.
    for _ in 0..<5 { watchdog.observe(zeros); try? await Task.sleep(nanoseconds: 10_000_000) }
    watchdog.observe(nonZero)
    for _ in 0..<5 { watchdog.observe(zeros); try? await Task.sleep(nanoseconds: 10_000_000) }
    watchdog.stop()
    #expect(!triggered)
}

@Test func watchdog_stopPreventsCallback() async {
    var triggered = false
    let watchdog = SilentFrameWatchdog(thresholdSeconds: 0.05) {
        triggered = true
    }
    watchdog.start()
    watchdog.stop()
    let zeros = Data(repeating: 0, count: 4 * 1000)
    watchdog.observe(zeros)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(!triggered)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SilentFrameWatchdogTests`

Expected: compile error.

- [ ] **Step 3: Implement `SilentFrameWatchdog`**

Create `Sources/UnisonDomain/SilentFrameWatchdog.swift`:

```swift
import Foundation

/// Detects prolonged all-zero amplitude on the peer audio stream and
/// fires a callback so the orchestrator can flip state to `.error`.
///
/// Production safety net for the case where macOS Process Tap delivers
/// silent buffers due to a TCC audio-capture denial — the call to
/// `AudioHardwareCreateProcessTap` itself succeeds, but the IOProc's
/// samples are all zero. We can't query TCC state from public API, so
/// observing the data is the only reliable detection.
public final class SilentFrameWatchdog: @unchecked Sendable {
    private let thresholdSeconds: TimeInterval
    private let onTriggered: @Sendable () -> Void
    private let queue = DispatchQueue(label: "unison.silent-frame-watchdog")
    private var firstSilentAt: Date?
    private var triggered = false
    private var running = false

    public init(thresholdSeconds: TimeInterval = 10,
                onTriggered: @escaping @Sendable () -> Void) {
        self.thresholdSeconds = thresholdSeconds
        self.onTriggered = onTriggered
    }

    public func start() {
        queue.sync {
            running = true
            triggered = false
            firstSilentAt = nil
        }
    }

    public func stop() {
        queue.sync {
            running = false
            firstSilentAt = nil
        }
    }

    /// Observe a chunk of PCM Float32 samples (the AudioFrame's `pcm`).
    /// Non-zero amplitude resets the silence timer; all-zero accumulates
    /// elapsed silence and triggers the callback once the threshold is
    /// crossed.
    public func observe(_ pcm: Data) {
        queue.sync {
            guard running, !triggered else { return }
            let isAllZero = pcmIsAllZero(pcm)
            let now = Date()
            if isAllZero {
                if firstSilentAt == nil { firstSilentAt = now }
                if let start = firstSilentAt,
                   now.timeIntervalSince(start) >= thresholdSeconds {
                    triggered = true
                    onTriggered()
                }
            } else {
                firstSilentAt = nil
            }
        }
    }

    private func pcmIsAllZero(_ data: Data) -> Bool {
        // Treat data as Float32 and check any non-zero sample.
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return true }
            let count = data.count / MemoryLayout<Float>.size
            for i in 0..<count {
                if base[i] != 0 { return false }
            }
            return true
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SilentFrameWatchdogTests`

Expected: 3 tests pass.

- [ ] **Step 5: Integrate watchdog into `TranslationOrchestrator`**

Open `Sources/UnisonDomain/TranslationOrchestrator.swift`. In `wireIncomingPipeline()`, instantiate the watchdog and observe the peer frames in the existing splitter Task (around line 788-795).

Locate this block (paths approximate):

```swift
peerFrames = peerCapture.start()
// Splitter task duplicating peerFrames → translationFrames + passthroughFrames
```

Add a watchdog instance scoped to the session:

```swift
let watchdog = SilentFrameWatchdog(thresholdSeconds: 10) { [weak self] in
    Task { @MainActor [weak self] in
        Self.log.error("Silent-frame watchdog tripped — TCC audio capture likely denied")
        self?.state = .error(.audioCaptureDenied)
    }
}
watchdog.start()
self.silentFrameWatchdog = watchdog  // hold strong ref for lifetime of session
```

In the splitter Task, after yielding each frame to translationFrames+passthroughFrames, observe its PCM:

```swift
for await frame in peerFrames {
    watchdog.observe(frame.pcm)
    // existing splitter logic: yield to translationFrames and passthroughFrames
}
```

In `stop()` / `stopAllStreams()`, stop the watchdog:

```swift
silentFrameWatchdog?.stop()
silentFrameWatchdog = nil
```

Add a stored property near other session-scoped properties:

```swift
private var silentFrameWatchdog: SilentFrameWatchdog?
```

Add the new error case in `TranslationError` (or equivalent error enum):

```swift
case audioCaptureDenied
```

And localized string in whatever error-localization helper exists:

```swift
case .audioCaptureDenied:
    return "Захват звука не разрешён в системе. Откройте Настройки → Конфиденциальность и безопасность → Микрофон."
```

(Adjust to match the existing pattern for other error case descriptions.)

- [ ] **Step 6: Run all tests**

Run: `swift build && swift test`

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/UnisonDomain/SilentFrameWatchdog.swift \
        Sources/UnisonDomain/TranslationOrchestrator.swift \
        Tests/UnisonDomainTests/SilentFrameWatchdogTests.swift
git commit -m "feat(orchestrator): SilentFrameWatchdog catches TCC denial at runtime"
```

---

## Task 9: Excluded Apps Settings UI

**Files:**
- Create: `Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift`
- Create: `Sources/UnisonUI/Views/Settings/ExcludedAppsPicker.swift`
- Modify: existing Settings view to include the new section

Goal: a Settings UI block for managing `settings.excludedTapBundleIDs`. List with rows + an `+ Добавить` button that opens a sheet picker showing audio processes.

- [ ] **Step 1: Create `ExcludedAppsSection.swift`**

Create `Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift`:

```swift
import AppKit
import SwiftUI
import UnisonAudio
import UnisonDomain

/// Settings section for managing the list of bundle IDs the Process Tap
/// will exclude from translation. Default empty; user can add running
/// audio apps via a picker sheet.
public struct ExcludedAppsSection: View {
    @Binding public var excludedBundleIDs: [String]
    @State private var showingPicker = false

    public init(excludedBundleIDs: Binding<[String]>) {
        self._excludedBundleIDs = excludedBundleIDs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Не переводить звук из:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if excludedBundleIDs.isEmpty {
                Text("Музыкальные плееры и другое — Unison будет их пропускать")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        appIcon(for: bundleID)
                            .frame(width: 18, height: 18)
                        Text(appDisplayName(for: bundleID))
                        Spacer()
                        Button {
                            excludedBundleIDs.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "xmark")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }

            Button("+ Добавить") {
                showingPicker = true
            }
            .buttonStyle(.link)
        }
        .sheet(isPresented: $showingPicker) {
            ExcludedAppsPicker(
                already: Set(excludedBundleIDs),
                onSelect: { bundleID in
                    if !excludedBundleIDs.contains(bundleID) {
                        excludedBundleIDs.append(bundleID)
                    }
                    showingPicker = false
                },
                onCancel: { showingPicker = false }
            )
        }
    }

    private func appIcon(for bundleID: String) -> some View {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        if let icon = app?.icon {
            return AnyView(Image(nsImage: icon).resizable())
        }
        return AnyView(Image(systemName: "app").foregroundStyle(.secondary))
    }

    private func appDisplayName(for bundleID: String) -> String {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        return app?.localizedName ?? bundleID
    }
}
```

- [ ] **Step 2: Create `ExcludedAppsPicker.swift`**

Create `Sources/UnisonUI/Views/Settings/ExcludedAppsPicker.swift`:

```swift
import AppKit
import SwiftUI
import UnisonAudio

/// Modal sheet for picking an audio-producing app to add to the
/// exclusion list. Shows all CoreAudio Audio Process Objects (apps that
/// have produced audio at least once during this session).
struct ExcludedAppsPicker: View {
    let already: Set<String>
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    @State private var processes: [AudioProcess] = []

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text("Добавить приложение")
                    .font(.headline)
                Spacer()
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.bottom, 8)

            if processes.isEmpty {
                Text("Нет запущенных аудио-приложений")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(processes.filter { !already.contains($0.bundleID) }) { process in
                    Button {
                        onSelect(process.bundleID)
                    } label: {
                        HStack {
                            icon(for: process)
                                .frame(width: 20, height: 20)
                            VStack(alignment: .leading) {
                                Text(process.name)
                                Text(process.bundleID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if process.isProducingAudio {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(width: 360, height: 360)
        .onAppear {
            processes = AudioProcessRegistry.runningAudioProcesses()
        }
    }

    private func icon(for process: AudioProcess) -> some View {
        if let path = process.bundlePath {
            let nsIcon = NSWorkspace.shared.icon(forFile: path)
            return AnyView(Image(nsImage: nsIcon).resizable())
        }
        return AnyView(Image(systemName: "app").foregroundStyle(.secondary))
    }
}
```

- [ ] **Step 3: Wire the section into the Settings window**

Find the Settings view file (likely `Sources/UnisonUI/Views/Settings/SettingsView.swift` or similar). Add a binding to the new field and include the section:

```swift
// In the Settings view body, after the Audio devices group:
ExcludedAppsSection(excludedBundleIDs: $settings.excludedTapBundleIDs)
```

If the surrounding view uses an `@Bindable` settings object or a published view-model, ensure the binding shape matches.

- [ ] **Step 4: Verify build**

Run: `swift build`

Expected: clean. SwiftUI views are not unit-tested in this project (snapshot tests cover them — those may need refresh).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/Views/Settings/
git commit -m "feat(settings): Excluded apps section with picker sheet"
```

---

## Task 10: Tap logging integration

**Files:**
- Modify: `Sources/UnisonAudio/ProcessTapCapture.swift`

Goal: four new log lines per session as specified in the design's "Logging" section.

- [ ] **Step 1: Add logger + log calls**

Open `Sources/UnisonAudio/ProcessTapCapture.swift`. Add a logger property near the top of the class:

```swift
private let log = UnisonLog(category: "ProcessTapCapture")
```

(If `UnisonLog` is not visible from `UnisonAudio`, add the appropriate import — look at how `BundledBlackHoleInstaller.swift` does it. If `UnisonLog` is in `UnisonSystem`, you may need a small refactor to expose it; alternatively use `os.Logger` with subsystem `"com.unison.app"` directly.)

Add log calls at the right points:

In `start()`, after `resolveExcludedProcessObjects()` succeeds, add:

```swift
let bundleIDsList = self.excludedBundleIDs.joined(separator: ", ")
self.log.info("[tap.start] excluded=\(bundleIDsList.isEmpty ? "<self only>" : bundleIDsList) processObjectIDs=\(self.processObjectIDs)")
```

In a hypothetical "all-zero detected" hook — the watchdog (Task 8) already logs; do not duplicate here. But add a one-time TCC status note at start:

```swift
// We can't query TCC state from public API; log "unknown" as a hint
// that runtime watchdog will be the authoritative check.
self.log.info("[tap.tcc] kTCCServiceAudioCapture status=notQueryable (silent-frame watchdog will verify at runtime)")
```

In `stop()`, log the reason:

```swift
public func stop() {
    self.log.info("[tap.stop] reason=user")
    teardown()
    continuation?.finish()
    continuation = nil
    started = false
}
```

In the catch block in `start()`:

```swift
} catch {
    self.log.error("[tap.stop] reason=error: \(error)")
    c.finish()
    self.teardown()
}
```

And in `deinit`:

```swift
deinit {
    self.log.info("[tap.stop] reason=deinit")
    teardown()
    continuation?.finish()
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`

Expected: clean.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonAudio/ProcessTapCapture.swift
git commit -m "feat(unison-audio): ProcessTapCapture diagnostic logging (start/stop/excluded)"
```

---

## Task 11: Delete BlackHole 16ch dead code

**Files:**
- Delete: `Sources/UnisonAudio/BlackHoleSinkCapture.swift`
- Delete: `Tests/UnisonAudioTests/BlackHoleSinkCaptureTests.swift` (if exists)
- Modify: `Sources/UnisonAudio/CoreAudioDeviceRegistry.swift` (delete `findBlackHole16ch`)

Goal: clean removal of all BH 16ch code that no longer has callers.

- [ ] **Step 1: Confirm no callers remain**

Run: `grep -rn "findBlackHole16ch\|BlackHoleSinkCapture\|blackHole16chMissing\|is16chInstalled" Sources/ Tests/`

Expected: ZERO matches in Sources/, possibly some in Tests/ for stale fixtures.

If matches in Sources/ exist, STOP and report — they're from a missed task above.

- [ ] **Step 2: Delete `BlackHoleSinkCapture.swift`**

```bash
git rm Sources/UnisonAudio/BlackHoleSinkCapture.swift
```

- [ ] **Step 3: Delete `BlackHoleSinkCaptureTests.swift` if it exists**

```bash
[ -f Tests/UnisonAudioTests/BlackHoleSinkCaptureTests.swift ] && \
  git rm Tests/UnisonAudioTests/BlackHoleSinkCaptureTests.swift || \
  echo "no test file to remove"
```

- [ ] **Step 4: Delete `findBlackHole16ch()` from `CoreAudioDeviceRegistry.swift`**

Open `Sources/UnisonAudio/CoreAudioDeviceRegistry.swift`. Delete this method (was around line 42):

```swift
public func findBlackHole16ch() -> AudioDevice? {
    allDevices().first { $0.name.lowercased().contains("blackhole 16ch") }
}
```

Keep `findBlackHole2ch()` and `allDevices()`.

- [ ] **Step 5: Final grep — verify clean**

Run: `grep -rn "16ch\|blackHole16chMissing" Sources/ Tests/ | grep -v "//"`

Expected: matches only in legitimate places (e.g., comments referring to "the old 16ch architecture" in a design doc that may still live in `docs/`, or installer test fixtures that ALSO contain the 16ch asset URL since the GitHub release has both — those are OK). Code references to 16ch in the runtime path must be zero.

- [ ] **Step 6: Verify build + all tests**

Run: `swift build && swift test`

Expected: all tests pass, no warnings about unused code.

- [ ] **Step 7: Commit**

```bash
git add Sources/UnisonAudio/CoreAudioDeviceRegistry.swift
git commit -m "refactor: remove BlackHole 16ch dead code (BlackHoleSinkCapture, findBlackHole16ch)"
```

---

## Task 12: Update CLAUDE.md and project docs

**Files:**
- Modify: `CLAUDE.md`
- Modify: `scripts/VM_README.md` (if mentions 16ch)
- Modify: `README.md` (if exists and mentions 16ch)

Goal: project documentation reflects the new inbound capture architecture.

- [ ] **Step 1: Find all 16ch mentions in docs**

Run: `grep -rn "16ch\|BlackHole 16\|BlackHoleSinkCapture" CLAUDE.md README.md scripts/*.md scripts/*.sh 2>/dev/null`

- [ ] **Step 2: Update `CLAUDE.md`**

For each occurrence:
- If it describes "current architecture" — rewrite to reflect Process Tap as inbound, BH 2ch as outbound only
- If it's in a "Debug / harness env vars" or similar table — keep test-only references intact (test fixtures may still install both)
- If it's prescriptive ("install BlackHole 16ch") — update wording

Specifically, the section "Liquid Glass — two backends behind one API" does not reference 16ch — skip it. Other architecture sections may need an update.

- [ ] **Step 3: Update `scripts/VM_README.md`**

Look for references to BH 16ch in:
- VM setup instructions
- Test scenario descriptions

If the VM setup pre-installs BH 16ch (likely it doesn't — the spec says it's optional now), no change needed. If env vars reference 16ch (e.g. `UNISON_FORCE_STATE=...` documentation), keep them but add a note that BH 16ch is no longer required at runtime.

- [ ] **Step 4: Update `README.md` if present**

Apply the same logic.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md scripts/VM_README.md README.md 2>/dev/null || true
git commit -m "docs: update CLAUDE.md and READMEs for Process Tap architecture"
```

---

## Task 13: Manual host smoke test

Goal: a person (the implementer) launches Unison from this branch and validates the end-to-end flow. This is a manual check, no code change.

- [ ] **Step 1: Build the bundle**

Run: `bash scripts/bundle_app.sh`

(Without `--target` flag, defaults to `unison`.)

Expected: `build/Unison.app` created, ad-hoc signed.

- [ ] **Step 2: Launch via Finder (NOT from terminal)**

```bash
open build/Unison.app
```

Why Finder: TCC's "responsible parent" attribution lands on the .app itself, not on the shell.

- [ ] **Step 3: Complete onboarding**

Expected behavior:
- "Аудио" step shows two rows: "Виртуальный микрофон (BlackHole 2ch)" and "Захват системного звука"
- Click "Установить" — BH 2ch installer flow (skips if already installed)
- Click "Разрешить" — macOS TCC prompt appears: "Unison wants to capture audio"
- Click Allow → row becomes ✓
- Microphone step: standard mic permission
- API key step: enter key
- Onboarding closes

- [ ] **Step 4: Start translation**

Open Zoom, Google Meet in Chrome, or any meeting source. Click Start in Unison popover.

Expected:
- Transcript window shows incoming audio being transcribed
- Original volume slider works (mute → only translation, full → both)
- Meeting audio is heard via Unison's mixer (Zoom's direct output is muted on the device level by `mutedWhenTapped`)

- [ ] **Step 5: Test Excluded apps**

- Open Spotify (or any music player), start playing
- In Unison Settings → "Не переводить звук из:" → "+ Добавить" → pick Spotify
- Stop translation, Start again
- Expected: meeting audio is captured + translated, Spotify continues to play and is NOT captured

- [ ] **Step 6: Test TCC denial path**

- Quit Unison
- Open System Settings → Privacy & Security → Audio Capture (or Microphone)
- Revoke Unison's permission
- Launch Unison, click Start
- Expected: within ~10 s, silent-frame watchdog trips; banner shows "Захват звука не разрешён…" with deep link to System Settings
- Re-grant permission in System Settings, return to Unison, Start again — works

- [ ] **Step 7: Document any issues**

If any step above fails — STOP the rollout. Capture:
- The failing step
- Console output (`tail -100 ~/Library/Logs/Unison/unison.log`)
- TCC log (`log show --predicate 'subsystem CONTAINS "TCC" AND eventMessage CONTAINS "unison"' --last 5m --info`)

Otherwise, the integration is verified — ready to merge.

There is no commit for this task; it is a verification step.

---

## Self-Review (run after the plan is written, fix inline)

**Spec coverage check** (against `docs/superpowers/specs/2026-05-27-process-tap-integration-design.md`):

| Spec section | Covered by task |
| ------------ | --------------- |
| Replace `BlackHoleSinkCapture` with `ProcessTapCapture` | Task 2, 7, 11 |
| Stop installing BH 16ch | Task 4 |
| User-configurable Excluded apps | Tasks 1, 3, 9 |
| Original-volume slider preserved | Untouched; verified in Task 13 |
| Onboarding Audio setup with TCC trigger | Tasks 5, 6 |
| Existing-user migration (no special code) | Tasks 4, 5, 11 (cascade removes 16ch requirement) |
| `monoGlobalTapButExcludeProcesses` + `mutedWhenTapped` | Task 2 |
| New AudioProcessRegistry | Task 1 |
| Silent-frame watchdog for runtime TCC denial | Task 8 |
| 4 new log lines | Task 10 |
| Delete dead code (BlackHoleSinkCapture, findBlackHole16ch, etc.) | Task 11 |
| Update docs (CLAUDE.md etc.) | Task 12 |

All sections covered.

**Placeholder scan:** No "TBD" / "fill in details" / "similar to Task N" — every step has explicit code or commands.

**Type consistency:**
- `excludedTapBundleIDs: [String]` used identically across Settings (Task 3), Composition (Task 7), ProcessTapCapture (Task 2)
- `AudioProcessRegistry.processObjectID(forBundleID:)` defined in Task 1, called from Task 2
- `AudioCapturePermission.triggerPrompt()` defined in Task 2, called from Task 5
- `SilentFrameWatchdog.observe(_:)` defined in Task 8, called from Task 8's integration
- `OnboardingStepStatus` (`.pending`/`.inProgress`/`.done`/`.error`) — existing type, reused for sub-states in Task 5

All consistent.
