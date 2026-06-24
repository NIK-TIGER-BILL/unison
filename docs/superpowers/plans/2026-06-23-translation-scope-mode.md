# Translation Scope Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings toggle between "translate everything except selected apps" (current blocklist) and "translate only selected apps" (new allowlist), each with its own app list, blocking start when the allowlist is empty.

**Architecture:** A persisted `TapScopeMode` enum + a second bundle-ID list in `Settings`. `ProcessTapCapture` takes a `TapScope` (`.allExcept`/`.onlySelected`) instead of a bare excluded list and picks the matching `CATapDescription` initializer; its existing process-list listener keeps the live tap correct in both modes. The popover's `StartBlockedReason` gains an empty-allowlist case. Settings UI gets a segmented control with mode-adaptive copy.

**Tech Stack:** Swift 6 (strict concurrency), SwiftUI + AppKit, CoreAudio Process Tap, Swift Testing (`@Test`/`#expect`), SwiftLint `--strict`.

---

## File Structure

- `Sources/UnisonDomain/TapScopeMode.swift` *(new)* — the persisted mode enum.
- `Sources/UnisonDomain/Settings.swift` *(modify)* — add `tapScopeMode`, `includedTapBundleIDs`, `activeTapBundleIDs`.
- `Sources/UnisonAudio/TapScope.swift` *(new)* — the runtime scope value passed to the capture.
- `Sources/UnisonAudio/ProcessTapCapture.swift` *(modify)* — generalize from excluded-list to `TapScope`.
- `Sources/UnisonAudio/AudioCapturePermission.swift` *(modify)* — update one call site.
- `Sources/Tools/TapBenchmark/BenchmarkRun.swift` *(no change)* — `ProcessTapCapture()` still compiles via the default scope.
- `Sources/UnisonApp/Composition.swift` *(modify)* — build a `TapScope` from settings.
- `Sources/UnisonUI/ViewModels/PopoverViewModel.swift` *(modify)* — add `.noAppsToTranslate` blocked reason.
- `Sources/UnisonUI/ViewModels/SettingsViewModel.swift` *(modify)* — mode setter + active-list get/set.
- `Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift` → rename to `AppScopeSection.swift` *(modify)* — segmented control + adaptive copy.
- `Sources/UnisonUI/Views/Settings/ExcludedAppsPicker.swift` → rename to `AppScopePicker.swift` *(rename only)*.
- `Sources/UnisonUI/Views/SettingsView.swift` *(modify)* — wire the section to mode + active list.
- `Sources/UnisonUI/Views/PopoverView.swift` *(modify)* — WarnRow for the empty-allowlist hint.
- Tests: `Tests/UnisonDomainTests/SettingsTests.swift`, `Tests/UnisonDomainTests/SettingsViewModelTests.swift`, `Tests/UnisonDomainTests/PopoverViewModelTests.swift`, `Tests/UnisonUITests/SettingsViewSnapshotTests.swift`.

---

### Task 1: `TapScopeMode` + `Settings` fields + migration

**Files:**
- Create: `Sources/UnisonDomain/TapScopeMode.swift`
- Modify: `Sources/UnisonDomain/Settings.swift`
- Test: `Tests/UnisonDomainTests/SettingsTests.swift`

- [ ] **Step 1: Write failing tests** in `Tests/UnisonDomainTests/SettingsTests.swift` (append):

```swift
@Test func settings_tapScopeMode_defaultsToAllExcept() {
    #expect(Settings().tapScopeMode == .allExcept)
    #expect(Settings().includedTapBundleIDs.isEmpty)
}

@Test func settings_activeTapBundleIDs_followsMode() {
    var s = Settings()
    s.excludedTapBundleIDs = ["com.exclude.one"]
    s.includedTapBundleIDs = ["com.include.one"]
    s.tapScopeMode = .allExcept
    #expect(s.activeTapBundleIDs == ["com.exclude.one"])
    s.tapScopeMode = .onlySelected
    #expect(s.activeTapBundleIDs == ["com.include.one"])
}

@Test func settings_scopeFields_codableRoundTrip() throws {
    var s = Settings()
    s.tapScopeMode = .onlySelected
    s.includedTapBundleIDs = ["com.apple.Music"]
    s.excludedTapBundleIDs = ["com.spotify.client"]
    let decoded: Settings = try encodeDecode(s)
    #expect(decoded == s)
}

@Test func settings_scopeFields_legacyJSONDecodesToDefaults() throws {
    // Settings persisted before this feature: no scope keys.
    let legacyJSON = """
    {
        "sessionMode": "call",
        "languagePair": { "mine": "ru", "peer": "en" },
        "excludedTapBundleIDs": ["com.spotify.client"],
        "originalMixVolume": 0.2
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Settings.self, from: legacyJSON)
    #expect(decoded.tapScopeMode == .allExcept)
    #expect(decoded.includedTapBundleIDs.isEmpty)
    #expect(decoded.excludedTapBundleIDs == ["com.spotify.client"])
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter "UnisonDomainTests.settings_tapScopeMode_defaultsToAllExcept"`
Expected: FAIL — `value of type 'Settings' has no member 'tapScopeMode'`.

- [ ] **Step 3: Create `Sources/UnisonDomain/TapScopeMode.swift`**

```swift
/// Whether the Process Tap translates everything *except* the chosen apps
/// (blocklist) or *only* the chosen apps (allowlist). The two are mutually
/// exclusive and each keeps its own list (`Settings.excludedTapBundleIDs`
/// vs `Settings.includedTapBundleIDs`).
public enum TapScopeMode: String, Codable, Sendable, CaseIterable {
    /// Translate all system audio except the listed apps. Default.
    case allExcept
    /// Translate only the listed apps; everything else is untouched.
    case onlySelected
}
```

- [ ] **Step 4: Modify `Sources/UnisonDomain/Settings.swift`** — add the stored properties, the computed active list, init params, coding keys, and decode defaults.

Add stored properties after `excludedTapBundleIDs` (line 6):

```swift
    public var excludedTapBundleIDs: [String]
    public var includedTapBundleIDs: [String]
    public var tapScopeMode: TapScopeMode
```

Add the computed active list after `originalMixVolume` (after line 12):

```swift
    /// The app list that applies to the current mode.
    public var activeTapBundleIDs: [String] {
        tapScopeMode == .onlySelected ? includedTapBundleIDs : excludedTapBundleIDs
    }
```

Extend `init` (add two params before `originalMixVolume`, and assign):

```swift
    public init(
        sessionMode: SessionMode = .call,
        languagePair: LanguagePair = .default,
        inputDeviceUID: String? = nil,
        outputDeviceUID: String? = nil,
        excludedTapBundleIDs: [String] = [],
        includedTapBundleIDs: [String] = [],
        tapScopeMode: TapScopeMode = .allExcept,
        originalMixVolume: Float = 0.2
    ) {
        self.sessionMode = sessionMode
        self.languagePair = languagePair
        self.inputDeviceUID = inputDeviceUID
        self.outputDeviceUID = outputDeviceUID
        self.excludedTapBundleIDs = excludedTapBundleIDs
        self.includedTapBundleIDs = includedTapBundleIDs
        self.tapScopeMode = tapScopeMode
        self._originalMixVolume = min(max(originalMixVolume, 0.0), 1.0)
    }
```

Extend `CodingKeys`:

```swift
    private enum CodingKeys: String, CodingKey {
        case sessionMode, languagePair, inputDeviceUID, outputDeviceUID
        case excludedTapBundleIDs, includedTapBundleIDs, tapScopeMode
        case _originalMixVolume = "originalMixVolume"
    }
```

Extend the decoder (after the `excludedTapBundleIDs` decode at line 44-45):

```swift
        self.excludedTapBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .excludedTapBundleIDs) ?? []
        self.includedTapBundleIDs = try c.decodeIfPresent([String].self,
                                                          forKey: .includedTapBundleIDs) ?? []
        self.tapScopeMode = try c.decodeIfPresent(TapScopeMode.self,
                                                  forKey: .tapScopeMode) ?? .allExcept
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `swift test --filter "UnisonDomainTests"`
Expected: PASS, including the four new tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonDomain/TapScopeMode.swift Sources/UnisonDomain/Settings.swift Tests/UnisonDomainTests/SettingsTests.swift
git commit -m "feat(domain): add TapScopeMode + included list to Settings"
```

---

### Task 2: `TapScope` + generalize `ProcessTapCapture`

**Files:**
- Create: `Sources/UnisonAudio/TapScope.swift`
- Modify: `Sources/UnisonAudio/ProcessTapCapture.swift`
- Modify: `Sources/UnisonAudio/AudioCapturePermission.swift:30`
- Modify: `Sources/UnisonApp/Composition.swift:152-154`

No new unit test (CoreAudio tap behavior isn't unit-testable); correctness is build + existing suite + manual verification.

- [ ] **Step 1: Create `Sources/UnisonAudio/TapScope.swift`**

```swift
/// What the Process Tap should capture, resolved from `Settings` at session
/// start. `.allExcept` taps everything but the listed bundle IDs (plus
/// Unison itself); `.onlySelected` taps only the listed bundle IDs.
public enum TapScope: Sendable, Equatable {
    case allExcept([String])
    case onlySelected([String])

    /// The user-chosen bundle IDs, regardless of mode. Empty means "no user
    /// selection" (for `.allExcept` that's tap-all; for `.onlySelected` the
    /// start gate prevents reaching this).
    public var bundleIDs: [String] {
        switch self {
        case .allExcept(let ids), .onlySelected(let ids): return ids
        }
    }
}
```

- [ ] **Step 2: Modify `ProcessTapCapture.swift` — initializers.** Replace the two existing `init`s and the `excludedBundleIDsProvider` stored property.

Replace the stored property (line 14) and rename `processObjectIDs` for clarity:

```swift
    private let scopeProvider: @Sendable () -> TapScope
    private var tappedObjectIDs: [AudioObjectID] = []  // last-applied, for change detection
```

Replace both initializers (lines 24-34):

```swift
    /// Static-scope init (tests, benchmark, permission probe). Defaults to a
    /// blocklist with no user exclusions = tap everything except self.
    public init(scope: TapScope = .allExcept([])) {
        self.scopeProvider = { scope }
        self.log = UnisonLog(category: "ProcessTapCapture")
    }

    /// Closure-based init (production — re-reads on every start).
    public init(scopeProvider: @escaping @Sendable () -> TapScope) {
        self.scopeProvider = scopeProvider
        self.log = UnisonLog(category: "ProcessTapCapture")
    }
```

- [ ] **Step 3: Modify `ProcessTapCapture.swift` — resolution + description builder.** Replace `resolveExcludedProcessObjects()` and `resolvedExclusionObjectIDs()` (the block starting at `private func resolveExcludedProcessObjects()`):

```swift
    private func applyInitialScope() {
        let (scope, ids) = resolveScope()
        tappedObjectIDs = ids
        log.info("[tap.start] scope=\(scope) tappedObjectIDs=\(ids)")
    }

    /// Resolve the active scope's bundle IDs to live Audio Process Object
    /// IDs. `.allExcept` always includes self (anti-feedback); `.onlySelected`
    /// never taps self. Apps with no audio object yet are skipped — the
    /// process-list listener re-resolves once they appear.
    private func resolveScope() -> (scope: TapScope, ids: [AudioObjectID]) {
        let scope = scopeProvider()
        var ids: [AudioObjectID] = []
        if case .allExcept = scope, let own = AudioProcessRegistry.processObjectID(forPID: getpid()) {
            ids.append(own)
        }
        for bundleID in scope.bundleIDs {
            if let obj = AudioProcessRegistry.processObjectID(forBundleID: bundleID) {
                ids.append(obj)
            }
        }
        return (scope, ids)
    }

    private func makeTapDescription(scope: TapScope, ids: [AudioObjectID]) -> CATapDescription {
        let desc: CATapDescription
        switch scope {
        case .allExcept:    desc = CATapDescription(monoGlobalTapButExcludeProcesses: ids)
        case .onlySelected: desc = CATapDescription(monoMixdownOfProcesses: ids)
        }
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped
        return desc
    }
```

- [ ] **Step 4: Modify `ProcessTapCapture.swift` — `start()` and `createTap()`.**

In `start()`, replace `self.resolveExcludedProcessObjects()` with `self.applyInitialScope()`.

Replace `createTap()`'s description construction so it uses the builder:

```swift
    private func createTap() throws {
        let (scope, ids) = resolveScope()
        tappedObjectIDs = ids
        let desc = makeTapDescription(scope: scope, ids: ids)
        let status = AudioHardwareCreateProcessTap(desc, &tapObjectID)
        try check(status, "AudioHardwareCreateProcessTap")
        guard tapObjectID != kAudioObjectUnknown else {
            throw ProcessTapError.tapCreationFailed
        }
    }
```

(Remove the now-redundant `applyInitialScope()` call in `start()` if `createTap()` already resolves — keep `applyInitialScope()` only for the log line, or fold the log into `createTap()`. Simplest: delete `applyInitialScope()` and move its `log.info` into `createTap()` after `tappedObjectIDs = ids`:)

```swift
        tappedObjectIDs = ids
        log.info("[tap.start] scope=\(scope) tappedObjectIDs=\(ids)")
        let desc = makeTapDescription(scope: scope, ids: ids)
```

And in `start()` delete the `self.resolveExcludedProcessObjects()` / `self.applyInitialScope()` line entirely (resolution now happens inside `createTap()`).

- [ ] **Step 5: Modify `ProcessTapCapture.swift` — listener install + refresh.** Replace `installProcessListListener()`'s guard and `refreshTapExclusions()`:

```swift
    private func installProcessListListener() {
        // Install only when the user has a non-empty list whose resolution
        // can change as apps come and go. (Empty `.allExcept` = self only,
        // stable; empty `.onlySelected` is blocked from starting.)
        guard !scopeProvider().bundleIDs.isEmpty else { return }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshTapDescription()
        }
        processListListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block
        )
        refreshTapDescription()
    }
```

Rename `refreshTapExclusions()` → `refreshTapDescription()` and generalize:

```swift
    private func refreshTapDescription() {
        tapLock.lock()
        defer { tapLock.unlock() }
        guard started, tapObjectID != 0 else { return }

        let (scope, ids) = resolveScope()
        guard Set(ids) != Set(tappedObjectIDs) else { return }
        tappedObjectIDs = ids

        let desc = makeTapDescription(scope: scope, ids: ids)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var box = desc
        let size = UInt32(MemoryLayout<CATapDescription>.size)
        let status = withUnsafeMutablePointer(to: &box) { ptr in
            AudioObjectSetPropertyData(tapObjectID, &addr, 0, nil, size, ptr)
        }
        if status == noErr {
            log.info("[tap.update] scope refreshed tappedObjectIDs=\(ids)")
        } else {
            log.error("[tap.update] kAudioTapPropertyDescription set failed status=\(status)")
        }
    }
```

In `teardown()`, replace `processObjectIDs.removeAll()` with `tappedObjectIDs.removeAll()`.

- [ ] **Step 6: Update call site `Sources/UnisonAudio/AudioCapturePermission.swift:30`**

Change `let capture = ProcessTapCapture(excludedBundleIDs: [])` to:

```swift
        let capture = ProcessTapCapture()
```

- [ ] **Step 7: Update call site `Sources/UnisonApp/Composition.swift:152-154`**

Replace:

```swift
        let peerCap = ProcessTapCapture(scopeProvider: {
            let s = settingsStoreRef.load()
            return s.tapScopeMode == .onlySelected
                ? .onlySelected(s.includedTapBundleIDs)
                : .allExcept(s.excludedTapBundleIDs)
        })
```

- [ ] **Step 8: Build, verify it compiles**

Run: `swift build`
Expected: `Build complete!` with no errors. (`TapBenchmark`'s `ProcessTapCapture()` still resolves via the default scope.)

- [ ] **Step 9: Run the audio suite, verify no regression**

Run: `swift test --filter "UnisonAudioTests"`
Expected: PASS (existing tests unaffected).

- [ ] **Step 10: Commit**

```bash
git add Sources/UnisonAudio/TapScope.swift Sources/UnisonAudio/ProcessTapCapture.swift Sources/UnisonAudio/AudioCapturePermission.swift Sources/UnisonApp/Composition.swift
git commit -m "feat(audio): generalize ProcessTapCapture to TapScope (block/allow)"
```

---

### Task 3: Empty-allowlist start gate (`PopoverViewModel`)

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/PopoverViewModel.swift`
- Test: `Tests/UnisonDomainTests/PopoverViewModelTests.swift`

- [ ] **Step 1: Write failing tests** (append to `PopoverViewModelTests.swift`; mirror the existing `makeVM`/mock pattern already used in that file — `PopoverViewModel(orchestrator:permissions:deviceRegistry:settings:)`):

```swift
@Test @MainActor func popover_allowlistEmpty_blocksStart() {
    let perms = MockPermissionsService()
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    var settings = Settings.default            // .call, BlackHole present via mock
    settings.tapScopeMode = .onlySelected
    settings.includedTapBundleIDs = []
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: settings)
    #expect(vm.startBlockedReason == .noAppsToTranslate)
    #expect(vm.canStart == false)
}

@Test @MainActor func popover_allowlistWithApp_allowsStart() {
    let perms = MockPermissionsService()
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    var settings = Settings.default
    settings.tapScopeMode = .onlySelected
    settings.includedTapBundleIDs = ["us.zoom.xos"]
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: settings)
    #expect(vm.startBlockedReason == nil)
}

@Test @MainActor func popover_blocklistEmpty_doesNotBlockStart() {
    let perms = MockPermissionsService()
    let orch = makeOrchestratorForVM(perms: perms)
    let registry = MockAudioDeviceRegistry()
    var settings = Settings.default
    settings.tapScopeMode = .allExcept
    settings.excludedTapBundleIDs = []
    let vm = PopoverViewModel(orchestrator: orch, permissions: perms, deviceRegistry: registry, settings: settings)
    #expect(vm.startBlockedReason == nil)
}
```

> If `MockAudioDeviceRegistry` does not provide a BlackHole 2ch by default (which would surface `.blackHole2chMissing` first in `.call`), set `settings.sessionMode = .listen` in these three tests — `.listen` also uses the tap but needs no BlackHole. Verify against the existing `canStart`-passing test in the file (it shows which default makes `canStart` true) and match it.

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter "PopoverViewModelTests.popover_allowlistEmpty_blocksStart"`
Expected: FAIL — `.noAppsToTranslate` is not a member of `StartBlockedReason`.

- [ ] **Step 3: Add the enum case** in `PopoverViewModel.swift` (lines 5-8):

```swift
public enum StartBlockedReason: Equatable, Sendable {
    case micPermissionRequired
    case blackHole2chMissing
    case noAppsToTranslate
}
```

- [ ] **Step 4: Extend `startBlockedReason`** — add, after the BlackHole check (before `return nil` at line 275):

```swift
        // Allowlist mode with an empty list ⇒ nothing to translate. Only the
        // peer-capturing modes use the tap; `.test` is mic-only, so skip it.
        if mode != .test,
           settings.tapScopeMode == .onlySelected,
           settings.includedTapBundleIDs.isEmpty {
            return .noAppsToTranslate
        }
        return nil
```

- [ ] **Step 5: Run tests, verify they pass**

Run: `swift test --filter "PopoverViewModelTests"`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/UnisonUI/ViewModels/PopoverViewModel.swift Tests/UnisonDomainTests/PopoverViewModelTests.swift
git commit -m "feat(popover): block start when allowlist is empty"
```

---

### Task 4: `SettingsViewModel` — mode + active-list accessors

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/SettingsViewModel.swift`
- Test: `Tests/UnisonDomainTests/SettingsViewModelTests.swift`

- [ ] **Step 1: Write failing tests** (append to `SettingsViewModelTests.swift`; match the file's existing VM construction — reuse its `makeViewModel`/init helper):

```swift
@Test @MainActor func settingsVM_setTapScopeMode_persists() {
    let vm = makeSettingsVM()                 // existing helper in this file
    vm.setTapScopeMode(.onlySelected)
    #expect(vm.settings.tapScopeMode == .onlySelected)
}

@Test @MainActor func settingsVM_activeTapBundleIDs_routesByMode() {
    let vm = makeSettingsVM()
    vm.setTapScopeMode(.allExcept)
    vm.setActiveTapBundleIDs(["com.exclude.x"])
    #expect(vm.settings.excludedTapBundleIDs == ["com.exclude.x"])
    #expect(vm.settings.includedTapBundleIDs.isEmpty)

    vm.setTapScopeMode(.onlySelected)
    vm.setActiveTapBundleIDs(["com.include.y"])
    #expect(vm.settings.includedTapBundleIDs == ["com.include.y"])
    #expect(vm.settings.excludedTapBundleIDs == ["com.exclude.x"])  // untouched
    #expect(vm.activeTapBundleIDs == ["com.include.y"])
}
```

> If the file has no shared `makeSettingsVM()` helper, construct the VM inline exactly as the existing tests in this file do (same `SettingsViewModel(initial:deviceRegistry:onChange:keychain:installer:)` call used by `SettingsViewModelTests`).

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test --filter "SettingsViewModelTests.settingsVM_setTapScopeMode_persists"`
Expected: FAIL — no member `setTapScopeMode`.

- [ ] **Step 3: Add accessors** in `SettingsViewModel.swift`, next to `setExcludedTapBundleIDs` (line 198):

```swift
    public func setExcludedTapBundleIDs(_ ids: [String]) {
        settings.excludedTapBundleIDs = ids
        emitChange()
    }

    public func setTapScopeMode(_ mode: TapScopeMode) {
        settings.tapScopeMode = mode
        emitChange()
    }

    /// The app list for the current mode (excluded list in `.allExcept`,
    /// included list in `.onlySelected`).
    public var activeTapBundleIDs: [String] { settings.activeTapBundleIDs }

    public func setActiveTapBundleIDs(_ ids: [String]) {
        if settings.tapScopeMode == .onlySelected {
            settings.includedTapBundleIDs = ids
        } else {
            settings.excludedTapBundleIDs = ids
        }
        emitChange()
    }
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `swift test --filter "SettingsViewModelTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/ViewModels/SettingsViewModel.swift Tests/UnisonDomainTests/SettingsViewModelTests.swift
git commit -m "feat(settings-vm): tap scope mode + active-list accessors"
```

---

### Task 5: UI — segmented control, adaptive copy, picker rename, hint

**Files:**
- Rename: `Sources/UnisonUI/Views/Settings/ExcludedAppsPicker.swift` → `AppScopePicker.swift` (rename the struct `ExcludedAppsPicker` → `AppScopePicker`; no behavior change)
- Rename + modify: `Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift` → `AppScopeSection.swift`
- Modify: `Sources/UnisonUI/Views/SettingsView.swift`
- Modify: `Sources/UnisonUI/Views/PopoverView.swift`
- Test: `Tests/UnisonUITests/SettingsViewSnapshotTests.swift`

- [ ] **Step 1: Rename the picker.** `git mv Sources/UnisonUI/Views/Settings/ExcludedAppsPicker.swift Sources/UnisonUI/Views/Settings/AppScopePicker.swift`, then rename the struct:

```swift
struct AppScopePicker: View {
```

(Everything else in the file is unchanged.)

- [ ] **Step 2: Rename + rewrite the section.** `git mv Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift Sources/UnisonUI/Views/Settings/AppScopeSection.swift`, then replace its contents:

```swift
import AppKit
import SwiftUI
import UnisonAudio
import UnisonDomain

/// Settings section for choosing what the Process Tap translates: either
/// everything except the listed apps (`.allExcept`) or only the listed apps
/// (`.onlySelected`). The mode segmented control sits above a single app
/// list bound to the active mode's selection.
public struct AppScopeSection: View {
    @Binding public var mode: TapScopeMode
    @Binding public var bundleIDs: [String]
    @State private var showingPicker = false

    public init(mode: Binding<TapScopeMode>, bundleIDs: Binding<[String]>) {
        self._mode = mode
        self._bundleIDs = bundleIDs
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $mode) {
                Text("Всё, кроме выбранных").tag(TapScopeMode.allExcept)
                Text("Только выбранные").tag(TapScopeMode.onlySelected)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(mode == .onlySelected ? "Переводить звук только из:" : "Не переводить звук из:")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if bundleIDs.isEmpty {
                Text(mode == .onlySelected
                     ? "Выберите приложения — остальное Unison не трогает"
                     : "Музыкальные плееры и другое — Unison будет их пропускать")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                ForEach(bundleIDs, id: \.self) { bundleID in
                    HStack {
                        appIcon(for: bundleID)
                            .frame(width: 18, height: 18)
                        Text(appDisplayName(for: bundleID))
                        Spacer()
                        Button {
                            bundleIDs.removeAll { $0 == bundleID }
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
            AppScopePicker(
                already: Set(bundleIDs),
                onSelect: { bundleID in
                    if !bundleIDs.contains(bundleID) {
                        bundleIDs.append(bundleID)
                    }
                    showingPicker = false
                },
                onCancel: { showingPicker = false }
            )
        }
    }

    @ViewBuilder
    private func appIcon(for bundleID: String) -> some View {
        if let icon = resolvedIcon(for: bundleID) {
            Image(nsImage: icon)
                .resizable()
        } else {
            Image(systemName: "app")
                .foregroundStyle(.secondary)
        }
    }

    private func resolvedIcon(for bundleID: String) -> NSImage? {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first?.icon {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    private func appDisplayName(for bundleID: String) -> String {
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return InstalledAppsRegistry.displayName(atPath: url.path)
        }
        return bundleID
    }
}
```

- [ ] **Step 3: Wire it in `SettingsView.swift`.** Replace the `excludedAppsSection` computed property (the `card(title: "Исключения") { ExcludedAppsSection(...) }` block):

```swift
    // MARK: - Section: App scope

    private var appScopeSection: some View {
        card(title: "Приложения") {
            AppScopeSection(
                mode: Binding(
                    get: { vm.settings.tapScopeMode },
                    set: { vm.setTapScopeMode($0) }
                ),
                bundleIDs: Binding(
                    get: { vm.activeTapBundleIDs },
                    set: { vm.setActiveTapBundleIDs($0) }
                )
            )
        }
    }
```

Then find where `excludedAppsSection` is referenced in `SettingsView`'s `body`/layout and rename that reference to `appScopeSection`.

Run to find it: `grep -n "excludedAppsSection" Sources/UnisonUI/Views/SettingsView.swift`

- [ ] **Step 4: Add the popover hint in `PopoverView.swift`.** Next to the same-language warning (lines 43-45), add:

```swift
            if !vm.isLanguagePairValid {
                WarnRow(message: "Выбран одинаковый язык")
            }
            if vm.startBlockedReason == .noAppsToTranslate {
                WarnRow(message: "Выберите приложения для перевода")
            }
```

- [ ] **Step 5: Build, verify it compiles**

Run: `swift build`
Expected: `Build complete!`. (Catches any missed `ExcludedAppsSection`/`ExcludedAppsPicker` reference.)

- [ ] **Step 6: Re-record the SettingsView snapshots** (the segmented control changes the rendered output):

Run: `RECORD_SNAPSHOTS=1 swift test --filter "UnisonUITests.SettingsViewSnapshotTests"`
Then re-run without the flag to verify:
Run: `swift test --filter "UnisonUITests.SettingsViewSnapshotTests"`
Expected: PASS. Inspect the regenerated PNGs under `Tests/UnisonUITests/__Snapshots__/` (or the repo's snapshot dir) before committing — confirm the segmented control renders and nothing else regressed.

- [ ] **Step 7: Commit**

```bash
git add Sources/UnisonUI/Views/Settings/ Sources/UnisonUI/Views/SettingsView.swift Sources/UnisonUI/Views/PopoverView.swift Tests/UnisonUITests/
git commit -m "feat(settings-ui): blocklist/allowlist segmented control + empty-allowlist hint"
```

---

### Task 6: Full verification

- [ ] **Step 1: Full build**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 2: Full test suite**

Run: `swift test`
Expected: all suites PASS.

- [ ] **Step 3: Lint (matches CI `--strict`)**

Run: `bash scripts/lint.sh swiftlint`
Expected: `Lint clean.` Fix any findings (e.g. trailing commas, line length) and re-run.

- [ ] **Step 4: Commit any lint fixes, then note manual verification**

The mode-specific tap behavior (allowlist taps only chosen apps; blocklist taps the rest; `.mutedWhenTapped` mutes the tapped set) is not exercised by the suite — it needs a real session on hardware. Manual check:
1. Settings → «Приложения» → «Только выбранные», add the conferencing app.
2. Start a session; confirm only that app is translated and other audio (music, etc.) plays at full volume.
3. Switch to «Всё, кроме выбранных»; confirm the chosen apps play untouched and the rest is translated.
4. «Только выбранные» with an empty list → Start is disabled with «Выберите приложения для перевода».

```bash
git add -A && git commit -m "style: lint fixes for translation scope mode" # only if lint changed files
```

---

## Self-Review

**Spec coverage:**
- Modes & tap semantics → Task 2 (`makeTapDescription`, `resolveScope`). ✓
- Data model + migration → Task 1. ✓
- `TapScope` + generalized capture → Task 2. ✓
- Dynamic listener both modes → Task 2 (Steps 5; guard on `scope.bundleIDs`). ✓
- Start gate empty allowlist → Task 3. ✓
- UI (segmented + adaptive copy) → Task 5. ✓
- Wiring (Composition) → Task 2 Step 7. ✓
- Testing (codable/migration, selector, start gate, snapshots) → Tasks 1, 3, 4, 5. ✓
- Copy strings → Task 5 (section) + Task 3/5 (hint). ✓

**Type consistency:** `TapScopeMode` (`.allExcept`/`.onlySelected`) used identically in Settings, TapScope mapping, PopoverViewModel gate, and the section Picker tags. `TapScope` cases match the `CATapDescription` initializer switch. `activeTapBundleIDs` defined on `Settings` (Task 1) and surfaced on `SettingsViewModel` (Task 4). `StartBlockedReason.noAppsToTranslate` defined (Task 3) and consumed in PopoverView (Task 5). `refreshTapDescription`/`tappedObjectIDs`/`resolveScope`/`makeTapDescription` named consistently across Task 2 steps.

**Placeholder scan:** No TBD/TODO; every code step shows full code. Two steps include a conditional fallback note (BlackHole default in tests; missing `makeSettingsVM` helper) with an explicit concrete action, not a deferral.
