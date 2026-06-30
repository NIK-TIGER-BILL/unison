import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - Shared mocks (HotkeyStorage / ToggleStorage)

private final class InMemoryHotkeyStore: HotkeyStorage, @unchecked Sendable {
    var stored: [HotkeyKind: Hotkey] = [:]
    func loadHotkey(_ kind: HotkeyKind) -> Hotkey? { stored[kind] }
    func saveHotkey(_ kind: HotkeyKind, _ hotkey: Hotkey?) {
        if let hotkey { stored[kind] = hotkey } else { stored.removeValue(forKey: kind) }
    }
}

private final class InMemoryToggleStore: ToggleStorage, @unchecked Sendable {
    var stored: [BehaviorToggle: Bool] = [:]
    func loadToggle(_ kind: BehaviorToggle, default fallback: Bool) -> Bool {
        stored[kind] ?? fallback
    }
    func saveToggle(_ kind: BehaviorToggle, _ value: Bool) {
        stored[kind] = value
    }
}

private final class FailingInstaller: BlackHoleInstaller, @unchecked Sendable {
    struct InstallError: Error {}
    var calls = 0
    var shouldFail = false
    var installed = true
    func is2chInstalled() -> Bool { installed }
    func runBundledInstaller() async throws {
        calls += 1
        if shouldFail { throw InstallError() }
        installed = true
    }
}

// MARK: - Existing tests (preserved)

@MainActor
@Test func settingsVM_changeInputDevice_persists() {
    var saved: Settings?
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { s in saved = s }
    )
    vm.setInputDeviceUID("airpods-uid")
    #expect(saved?.inputDeviceUID == "airpods-uid")
}

@MainActor
@Test func settingsVM_originalMixVolume_clampedAndPersisted() {
    var saved: Settings?
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { s in saved = s }
    )
    vm.setOriginalMixVolume(0.5)
    #expect(saved?.originalMixVolume == 0.5)
    vm.setOriginalMixVolume(2.0)
    #expect(saved?.originalMixVolume == 1.0)
}

// MARK: - Phase 3c additions

@MainActor
@Test func settingsVM_changeInputDevice_bumpsLastSavedAt() {
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in }
    )
    #expect(vm.lastSavedAt == nil)
    vm.setInputDeviceUID("airpods")
    #expect(vm.lastSavedAt != nil)
}

@MainActor
@Test func settingsVM_loadsAPIKeyFromKeychainOnInit() throws {
    let kc = MockKeychain()
    try kc.saveAPIKey("sk-init-1234567890", for: .openAIRealtime)
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        keychain: kc
    )
    #expect(vm.apiKey == "sk-init-1234567890")
}

@MainActor
@Test func settingsVM_updateApiKey_persistsToKeychain() {
    let kc = MockKeychain()
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        keychain: kc
    )
    vm.updateApiKey("sk-new-98765432109876543210")
    #expect(kc.loadAPIKey(for: .openAIRealtime) == "sk-new-98765432109876543210")
    #expect(vm.apiKey == "sk-new-98765432109876543210")
    #expect(vm.lastSavedAt != nil)
}

@MainActor
@Test func settingsVM_updateApiKey_partialEditDoesNotClobberStoredKey() throws {
    // Per-keystroke edits used to write truncated garbage into the
    // Keychain (and a ⌘A-retype transiently deleted the stored key).
    // A partial value must keep the previously stored key intact and
    // must NOT flash «сохранено».
    let kc = MockKeychain()
    try kc.saveAPIKey("sk-old-12345678901234567890", for: .openAIRealtime)
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        keychain: kc
    )
    vm.updateApiKey("sk-pro")  // mid-edit fragment
    #expect(kc.loadAPIKey(for: .openAIRealtime) == "sk-old-12345678901234567890", "Partial key must not overwrite the stored one")
    #expect(vm.apiKey == "sk-pro", "In-memory value tracks the field")
    #expect(vm.lastSavedAt == nil, "No save indicator for a write that didn't happen")
}

@MainActor
@Test func settingsVM_updateApiKey_emptyClearsKeychain() throws {
    let kc = MockKeychain()
    try kc.saveAPIKey("sk-old-1234567890", for: .openAIRealtime)
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        keychain: kc
    )
    #expect(vm.apiKey == "sk-old-1234567890")
    vm.updateApiKey("")
    #expect(kc.loadAPIKey(for: .openAIRealtime) == nil)
    #expect(vm.apiKey == "")
}

@MainActor
@Test func settingsVM_defaultHotkeys_seededOnInit() {
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in }
    )
    #expect(vm.hotkeyStartStop == .defaultStartStop)
    #expect(vm.hotkeyStartStop?.display == "⌃⌥U")
    #expect(vm.hotkeyShowTranscript == .defaultShowTranscript)
    #expect(vm.hotkeyShowTranscript?.display == "⌃⌥T")
}

@MainActor
@Test func settingsVM_loadHotkeyFromStore_overridesDefaults() {
    let store = InMemoryHotkeyStore()
    let custom = Hotkey(modifiers: [.command, .shift], keyChar: "K")
    store.stored[.startStop] = custom
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        hotkeyStore: store
    )
    #expect(vm.hotkeyStartStop == custom)
}

@MainActor
@Test func settingsVM_updateHotkey_persistsAndNotifies() {
    let store = InMemoryHotkeyStore()
    var notifiedStart: Hotkey?
    var notifiedShow: Hotkey?
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        hotkeyStore: store
    )
    vm.onHotkeysChanged = { start, transcript in
        notifiedStart = start
        notifiedShow = transcript
    }
    let newHotkey = Hotkey(modifiers: [.command, .option], keyChar: "P")
    vm.updateHotkey(.startStop, newHotkey)
    #expect(store.stored[.startStop] == newHotkey)
    #expect(vm.hotkeyStartStop == newHotkey)
    #expect(notifiedStart == newHotkey)
    #expect(notifiedShow == vm.hotkeyShowTranscript)
}

@MainActor
@Test func settingsVM_updateHotkey_clearsToNil() {
    let store = InMemoryHotkeyStore()
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        hotkeyStore: store
    )
    let original = vm.hotkeyShowTranscript
    #expect(original != nil)
    vm.updateHotkey(.showTranscript, nil)
    #expect(vm.hotkeyShowTranscript == nil)
    #expect(store.stored[.showTranscript] == nil)
}

@MainActor
@Test func settingsVM_recordingHotkey_setsAndClears() {
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in }
    )
    #expect(vm.recordingHotkey == nil)
    vm.beginRecordingHotkey(.startStop)
    #expect(vm.recordingHotkey == .startStop)
    vm.cancelRecordingHotkey()
    #expect(vm.recordingHotkey == nil)
}

@MainActor
@Test func settingsVM_togglesLoadFromStore() {
    let toggles = InMemoryToggleStore()
    toggles.stored[.autostart] = true
    toggles.stored[.hideMenuOnSession] = true
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        togglesStore: toggles
    )
    #expect(vm.autostart)
    #expect(vm.hideMenuOnSession)
}

@MainActor
@Test func settingsVM_updateAutostart_persistsAndStamps() {
    let toggles = InMemoryToggleStore()
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        togglesStore: toggles
    )
    #expect(vm.autostart == false)
    vm.updateAutostart(true)
    #expect(vm.autostart)
    #expect(toggles.stored[.autostart] == true)
    #expect(vm.lastSavedAt != nil)
}

@MainActor
@Test func settingsVM_updateHideMenu_persists() {
    let toggles = InMemoryToggleStore()
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        togglesStore: toggles
    )
    vm.updateHideMenuOnSession(true)
    #expect(vm.hideMenuOnSession)
    #expect(toggles.stored[.hideMenuOnSession] == true)
}

@MainActor
@Test func settingsVM_blackHoleStatus_readyWhenRegistryReports() {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: registry,
        onChange: { _ in }
    )
    #expect(vm.blackHole2chStatus == .ready)
}

@MainActor
@Test func settingsVM_blackHoleStatus_errorWhenMissing() {
    let registry = MockAudioDeviceRegistry()
    // No bh2ch set on the mock.
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: registry,
        onChange: { _ in }
    )
    #expect(vm.blackHole2chStatus == .error)
}

@MainActor
@Test func settingsVM_reinstallBlackHole_callsInstaller() async {
    let registry = MockAudioDeviceRegistry()
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    let installer = FailingInstaller()
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: registry,
        onChange: { _ in },
        installer: installer
    )
    #expect(vm.isReinstallingBlackHole == false)
    await vm.reinstallBlackHole()
    #expect(installer.calls == 1)
    #expect(vm.isReinstallingBlackHole == false)
    #expect(vm.lastSavedAt != nil)
    // After install: registry still reports installed → status .ready.
    #expect(vm.blackHole2chStatus == .ready)
}

@MainActor
@Test func settingsVM_reinstallBlackHole_failureLeavesErrorStatus() async {
    let registry = MockAudioDeviceRegistry()
    // No bh2ch: device registry will still report missing after the
    // installer "runs" — so blackHole status settles to `.error`.
    let installer = FailingInstaller()
    installer.shouldFail = true
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: registry,
        onChange: { _ in },
        installer: installer
    )
    await vm.reinstallBlackHole()
    #expect(installer.calls == 1)
    #expect(vm.isReinstallingBlackHole == false)
    #expect(vm.blackHole2chStatus == .error)
}

@MainActor
@Test func settingsVM_refreshBlackHoleStatus_picksUpHotPlug() {
    let registry = MockAudioDeviceRegistry()
    // Start without devices.
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: registry,
        onChange: { _ in }
    )
    #expect(vm.blackHole2chStatus == .error)
    // Device appears → manual refresh reflects it.
    registry.bh2ch = AudioDevice(uid: "bh2", name: "BlackHole 2ch", kind: .output)
    vm.refreshBlackHoleStatus()
    #expect(vm.blackHole2chStatus == .ready)
}

// MARK: - HotkeyStorage Codable round-trip

@Test func hotkeyStorage_codable_roundTrip() throws {
    let original = Hotkey(modifiers: [.control, .shift, .command], keyChar: "K", glyph: "⌘")
    let decoded = try encodeDecode(original)
    #expect(decoded == original)
    #expect(decoded.display == original.display)
}

@Test func defaultHotkeys_displayMatchesDesign() {
    #expect(Hotkey.defaultStartStop.display == "⌃⌥U")
    #expect(Hotkey.defaultShowTranscript.display == "⌃⌥T")
}

// MARK: - Task-9: model-aware key + language coercion

@MainActor @Test func switchingModelCoercesUnsupportedLanguages() {
    var saved: Settings?
    var s = Settings.default
    s.translationModel = .geminiLiveTranslate
    s.languagePair = LanguagePair(mine: .pl, peer: .en)   // Polish is Gemini-only
    let vm = SettingsViewModel(
        initial: s,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { saved = $0 }
    )
    vm.setTranslationModel(.openAIRealtime)
    #expect(vm.settings.translationModel == .openAIRealtime)
    #expect(TranslationModel.openAIRealtime.supportedTargets.contains(vm.settings.languagePair.mine))
    #expect(saved?.translationModel == .openAIRealtime)
}

@MainActor @Test func keyFieldReloadsForSelectedModel() throws {
    let kc = MockKeychain()
    try kc.saveAPIKey("sk-aaaaaaaaaaaaaaaaaaaa", for: .openAIRealtime)
    try kc.saveAPIKey("AQ.bbbbbbbbbbbbbbbbbbbb", for: .geminiLiveTranslate)
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in },
        keychain: kc
    )
    #expect(vm.apiKey == "sk-aaaaaaaaaaaaaaaaaaaa")     // default model = OpenAI
    vm.setTranslationModel(.geminiLiveTranslate)
    #expect(vm.apiKey == "AQ.bbbbbbbbbbbbbbbbbbbb")     // reloaded for Gemini slot
}

// MARK: - Tap scope mode accessors

@MainActor
@Test func settingsVM_setTapScopeMode_persists() {
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in }
    )
    vm.setTapScopeMode(.onlySelected)
    #expect(vm.settings.tapScopeMode == .onlySelected)
}

@MainActor
@Test func settingsVM_activeTapBundleIDs_routesByMode() {
    let vm = SettingsViewModel(
        initial: .default,
        deviceRegistry: MockAudioDeviceRegistry(),
        onChange: { _ in }
    )
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
