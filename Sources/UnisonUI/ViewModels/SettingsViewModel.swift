import Foundation
import Observation
import UnisonDomain

/// Identifier for one of the global hotkeys configured in Settings.
/// Lives in `UnisonUI` so the host (`UnisonApp`) can map the kind to a
/// Carbon `EventHotKeyID` when registering.
public enum HotkeyKind: String, CaseIterable, Codable, Sendable, Hashable {
    case startStop
    case showTranscript
}

/// Install status for a virtual audio device. Mirrors the design's
/// status-dot states: `.ready` (installed, green dot), `.warn` (mid-install,
/// yellow dot), `.error` (missing/failed, red dot).
public enum BlackHoleStatus: Equatable, Sendable {
    case ready
    case warn
    case error
    case installing
}

@MainActor
@Observable
public final class SettingsViewModel {
    public var settings: Settings
    private let deviceRegistry: any AudioDeviceRegistry
    private let onChange: (Settings) -> Void

    // MARK: - Optional dependencies (additive — keychain/installer/hotkeyStore)

    private let keychain: (any KeychainService)?
    private let installer: (any BlackHoleInstaller)?
    private let hotkeyStore: HotkeyStorage?
    private let togglesStore: ToggleStorage?

    // MARK: - State the new SettingsView consumes

    /// In-memory copy of the API key. Loaded from `keychain` in the
    /// initializer; saved back via `updateApiKey(_:)`. Empty when no
    /// key is set or no keychain is wired in (tests).
    public var apiKey: String
    /// Toggles the `SecretInput` between plain text and password mode.
    public var apiKeyVisible: Bool = false

    /// Configured global hotkeys. Default values match the design
    /// (`⌃⌥U` / `⌃⌥T`). Persisted via `hotkeyStore` when supplied.
    public var hotkeyStartStop: Hotkey? = .defaultStartStop
    public var hotkeyShowTranscript: Hotkey? = .defaultShowTranscript

    /// Which hotkey row the user is currently recording into. `nil`
    /// when no recording is active. The view sets this; the host
    /// observes and installs a key monitor.
    public var recordingHotkey: HotkeyKind? = nil

    /// User-facing behaviour toggles. Persisted via `togglesStore`.
    public var autostart: Bool = false
    public var hideMenuOnSession: Bool = false

    /// Current BlackHole install state, derived from `deviceRegistry`
    /// but overridden during a re-install to show the warn pulse.
    public var blackHole2chStatus: BlackHoleStatus = .ready
    public var blackHole16chStatus: BlackHoleStatus = .ready

    /// Stored mirrors of the input / output device lists. These were
    /// previously *computed* properties that called into the registry
    /// on every access — which meant SwiftUI's Observation tracking
    /// had nothing to watch and the picker dropdown never refreshed
    /// when the user plugged in a new mic / speaker after launch.
    /// Storing them lets Observation invalidate the view on
    /// `refreshDeviceList()` calls (wired by Composition to the
    /// CoreAudio device-list listener).
    public private(set) var availableInputs: [AudioDevice] = []
    public private(set) var availableOutputs: [AudioDevice] = []

    /// Set while a re-install is in flight — disables the inline
    /// button and swaps its label to "Установка…".
    public var isReinstallingBlackHole: Bool = false

    /// Sentinel used to drive `SaveIndicator` — bumps on every mutation
    /// that auto-saves. Views observe `lastSavedAt` and flash the
    /// indicator when it changes.
    public var lastSavedAt: Date? = nil

    /// Convenience callback fired *in addition* to `onChange`. Used by
    /// the host wiring to re-register hotkeys when they change.
    @ObservationIgnored
    public var onHotkeysChanged: ((Hotkey?, Hotkey?) -> Void)? = nil

    public init(
        initial: Settings,
        deviceRegistry: any AudioDeviceRegistry,
        onChange: @escaping (Settings) -> Void,
        keychain: (any KeychainService)? = nil,
        installer: (any BlackHoleInstaller)? = nil,
        hotkeyStore: HotkeyStorage? = nil,
        togglesStore: ToggleStorage? = nil
    ) {
        self.settings = initial
        self.deviceRegistry = deviceRegistry
        self.onChange = onChange
        self.keychain = keychain
        self.installer = installer
        self.hotkeyStore = hotkeyStore
        self.togglesStore = togglesStore

        // Seed the in-memory API key from Keychain (if configured).
        self.apiKey = keychain?.loadAPIKey() ?? ""

        // Seed hotkeys from persistent store, falling back to defaults.
        if let store = hotkeyStore {
            self.hotkeyStartStop = store.loadHotkey(.startStop) ?? .defaultStartStop
            self.hotkeyShowTranscript = store.loadHotkey(.showTranscript) ?? .defaultShowTranscript
        }

        // Seed toggles from persistent store.
        if let toggles = togglesStore {
            self.autostart = toggles.loadToggle(.autostart, default: false)
            self.hideMenuOnSession = toggles.loadToggle(.hideMenuOnSession, default: false)
        }

        // Seed BlackHole status from the registry.
        self.blackHole2chStatus = (deviceRegistry.findBlackHole2ch() != nil) ? .ready : .error
        self.blackHole16chStatus = (deviceRegistry.findBlackHole16ch() != nil) ? .ready : .error

        // Seed device lists. Composition rewires `onDeviceListChanged`
        // immediately after construction to keep them fresh while the
        // app is open.
        refreshDeviceList()
    }

    /// Re-read the device lists from the registry. Called once at init
    /// (to seed the stored properties) and again from Composition's
    /// `registry.onDeviceListChanged` hook whenever CoreAudio reports
    /// the hardware roster changed. Filters out BlackHole devices —
    /// they're internal plumbing, never user-selectable as mic or
    /// speaker.
    public func refreshDeviceList() {
        availableInputs = deviceRegistry.availableInputDevices().filter {
            !$0.name.lowercased().contains("blackhole")
        }
        availableOutputs = deviceRegistry.availableOutputDevices().filter {
            !$0.name.lowercased().contains("blackhole")
        }
    }

    /// Convenience exposed so views can call `vm.availableMics` per the
    /// plan's naming.
    public var availableMics: [AudioDevice] { availableInputs }
    public var availableSpeakers: [AudioDevice] { availableOutputs }

    // MARK: - Mutators (each calls `onChange` + bumps `lastSavedAt`)

    public func setLanguagePair(_ pair: LanguagePair) {
        settings.languagePair = pair
        emitChange()
    }

    public func setSessionMode(_ mode: SessionMode) {
        settings.sessionMode = mode
        emitChange()
    }

    public func setInputDeviceUID(_ uid: String?) {
        settings.inputDeviceUID = uid
        emitChange()
    }

    public func setOutputDeviceUID(_ uid: String?) {
        settings.outputDeviceUID = uid
        emitChange()
    }

    public func setOriginalMixVolume(_ v: Float) {
        settings.originalMixVolume = v
        emitChange()
    }

    /// Persist a new OpenAI API key. Writes to the configured Keychain
    /// (if any); the value is also kept in memory so the view's binding
    /// reflects the saved state without reloading. Empty values clear
    /// the key.
    public func updateApiKey(_ key: String) {
        apiKey = key
        if let keychain {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                try? keychain.deleteAPIKey()
            } else {
                try? keychain.saveAPIKey(trimmed)
            }
        }
        bumpSavedTimestamp()
    }

    /// Persist a recorded hotkey for the given kind. Re-broadcasts via
    /// `onHotkeysChanged` so the host can re-register the global combo.
    /// Passing `nil` clears the hotkey.
    ///
    /// Clears `recordingHotkey` as a side-effect: the host's
    /// `HotkeyService` calls this from its capture monitor, and the UI
    /// must drop out of "нажмите…" state as soon as the new combo
    /// lands. Without this reset the `HotkeyRecorder` label stays
    /// stuck on "нажмите…" forever (recording flag never flips off),
    /// which is the user-visible "hotkey recorder doesn't work" bug.
    public func updateHotkey(_ kind: HotkeyKind, _ hotkey: Hotkey?) {
        switch kind {
        case .startStop:       hotkeyStartStop = hotkey
        case .showTranscript:  hotkeyShowTranscript = hotkey
        }
        if recordingHotkey == kind {
            recordingHotkey = nil
        }
        hotkeyStore?.saveHotkey(kind, hotkey)
        onHotkeysChanged?(hotkeyStartStop, hotkeyShowTranscript)
        bumpSavedTimestamp()
    }

    public func updateAutostart(_ value: Bool) {
        autostart = value
        togglesStore?.saveToggle(.autostart, value)
        bumpSavedTimestamp()
    }

    public func updateHideMenuOnSession(_ value: Bool) {
        hideMenuOnSession = value
        togglesStore?.saveToggle(.hideMenuOnSession, value)
        bumpSavedTimestamp()
    }

    public func toggleApiKeyVisibility() {
        apiKeyVisible.toggle()
    }

    public func beginRecordingHotkey(_ kind: HotkeyKind) {
        recordingHotkey = kind
    }

    public func cancelRecordingHotkey() {
        recordingHotkey = nil
    }

    /// Re-runs the bundled `.pkg` installer. While running, flips both
    /// status dots to `.warn` and disables the inline button. On
    /// success / failure the dots resync from the registry. Caller is
    /// expected to wait via `await`.
    public func reinstallBlackHole() async {
        guard let installer else {
            // Nothing wired — still fake a UI tick so tests can observe.
            isReinstallingBlackHole = true
            blackHole2chStatus = .warn
            blackHole16chStatus = .warn
            isReinstallingBlackHole = false
            refreshBlackHoleStatus()
            bumpSavedTimestamp()
            return
        }
        isReinstallingBlackHole = true
        blackHole2chStatus = .warn
        blackHole16chStatus = .warn
        do {
            try await installer.runBundledInstaller()
        } catch {
            // Leave the status to settle from the registry below; if
            // the device still isn't there we'll surface `.error`.
        }
        isReinstallingBlackHole = false
        refreshBlackHoleStatus()
        bumpSavedTimestamp()
    }

    /// Re-reads BlackHole presence from the device registry and
    /// updates `blackHoleNchStatus`. Public so AppDelegate can call
    /// after a hot-plug event.
    public func refreshBlackHoleStatus() {
        blackHole2chStatus = (deviceRegistry.findBlackHole2ch() != nil) ? .ready : .error
        blackHole16chStatus = (deviceRegistry.findBlackHole16ch() != nil) ? .ready : .error
    }

    // MARK: - Private

    private func emitChange() {
        onChange(settings)
        bumpSavedTimestamp()
    }

    private func bumpSavedTimestamp() {
        lastSavedAt = Date()
    }
}

// MARK: - Default hotkeys

public extension Hotkey {
    /// Design default — `⌃⌥U` (start/stop session).
    static let defaultStartStop = Hotkey(
        modifiers: [.control, .option],
        keyChar: "U",
        glyph: nil
    )
    /// Design default — `⌃⌥T` (show transcript window).
    static let defaultShowTranscript = Hotkey(
        modifiers: [.control, .option],
        keyChar: "T",
        glyph: nil
    )
}

// MARK: - Storage protocols

/// Backing store for the two hotkeys configured in Settings. Implemented
/// in `UnisonApp` against `UserDefaults`; tests use in-memory doubles.
public protocol HotkeyStorage: Sendable {
    func loadHotkey(_ kind: HotkeyKind) -> Hotkey?
    func saveHotkey(_ kind: HotkeyKind, _ hotkey: Hotkey?)
}

public enum BehaviorToggle: String, Sendable, Hashable {
    case autostart
    case hideMenuOnSession
}

public protocol ToggleStorage: Sendable {
    func loadToggle(_ kind: BehaviorToggle, default fallback: Bool) -> Bool
    func saveToggle(_ kind: BehaviorToggle, _ value: Bool)
}
