import SwiftUI
import UnisonDomain

/// Settings window — single-column, auto-saving, native macOS Form.
///
/// We follow Apple's official "Adopting Liquid Glass" guidance for
/// Settings-style surfaces:
///
/// - Native `Form` + `.formStyle(.grouped)` supplies the title-case
///   `Section` headers, rounded section cards with subtle background,
///   row heights, and the macOS 26 translucent material backing.
/// - Native `Picker` with `.pickerStyle(.menu)` for every dropdown
///   (mic / speaker / mine language / peer language). The opened menu
///   is an `NSMenu` rendered above the window — it never gets clipped
///   by the form bounds and includes keyboard navigation, search, and
///   accessibility for free.
/// - The host `NSWindow` sets `backgroundColor = NSColor.windowBackgroundColor`
///   so the window itself supplies the Liquid Glass material; we do
///   **not** wrap the form in `.glassEffect` and we do not hide its
///   default scroll content background. The native form draws on the
///   system window material exactly like System Settings does.
///
/// `UnisonUI` cannot import `AppKit`, so any system action (opening a
/// URL, starting a global hotkey monitor) goes through the closures the
/// host supplies:
/// - `onOpenURL: (URL) -> Void`
/// - `onRecordHotkey: (HotkeyKind) -> Void`
public struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    /// Caller-provided URL opener (license, GitHub, OpenAI keys page).
    let onOpenURL: (URL) -> Void

    /// Host hook for hotkey recording. The host begins a local
    /// `NSEvent` monitor; when it captures a key combo it calls
    /// `vm.updateHotkey(...)` directly. This view only signals which
    /// row was tapped via `vm.beginRecordingHotkey(_:)`.
    let onRecordHotkey: (HotkeyKind) -> Void

    public init(
        vm: SettingsViewModel,
        onOpenURL: @escaping (URL) -> Void = { _ in },
        onRecordHotkey: @escaping (HotkeyKind) -> Void = { _ in }
    ) {
        self.vm = vm
        self.onOpenURL = onOpenURL
        self.onRecordHotkey = onRecordHotkey
    }

    /// Sentinel used by `Picker` for "system default" device. `Picker`
    /// requires a non-optional tag value, so we reserve the empty
    /// string as the "default" UID and map back to `nil` in the
    /// binding's setter.
    private static let defaultDeviceTag = ""

    /// Save-indicator controller — flashes "✓ сохранено" for ~1.6s
    /// whenever the VM bumps `lastSavedAt`.
    @SwiftUI.State private var saveIndicator = SaveIndicatorController()

    public var body: some View {
        Form {
            audioSection
            languagesSection
            openAISection
            hotkeysSection
            blackHoleSection
            behaviorSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        // The native form supplies its own translucent background and
        // grouped-section cards on macOS 26 — we don't override
        // `.scrollContentBackground` or layer custom glass on top.
        //
        // `.overlay` puts the SaveIndicator *above* the content rather
        // than inserting it into the layout flow. Two consequences:
        //   1. Showing/hiding the indicator never shifts the form rows
        //      (the user reported "весь текст сдвигается вниз и
        //      прыгает" with the old `.safeAreaInset` placement).
        //   2. The indicator floats over the form regardless of scroll
        //      position, so it stays visible even when the user has
        //      scrolled to the bottom of Settings (the user reported
        //      "Когда ты снизу настроек, не видно текста сохранено").
        // Bottom-trailing placement matches the System Settings save
        // convention on Tahoe.
        .overlay(alignment: .bottomTrailing) {
            SaveIndicator(isShown: Binding(
                get: { saveIndicator.isShown },
                set: { saveIndicator.isShown = $0 }
            ))
            .padding(.trailing, 16)
            .padding(.bottom, 12)
            .allowsHitTesting(false)
        }
        .onChange(of: vm.lastSavedAt) { _, _ in
            saveIndicator.markSaved()
        }
    }

    // MARK: - Section: Audio

    private var audioSection: some View {
        Section("Аудио") {
            Picker("Микрофон", selection: Binding(
                get: { vm.settings.inputDeviceUID ?? Self.defaultDeviceTag },
                set: { uid in
                    vm.setInputDeviceUID(uid == Self.defaultDeviceTag ? nil : uid)
                }
            )) {
                Text("По умолчанию").tag(Self.defaultDeviceTag)
                ForEach(vm.availableMics, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)

            Picker("Динамик", selection: Binding(
                get: { vm.settings.outputDeviceUID ?? Self.defaultDeviceTag },
                set: { uid in
                    vm.setOutputDeviceUID(uid == Self.defaultDeviceTag ? nil : uid)
                }
            )) {
                Text("По умолчанию").tag(Self.defaultDeviceTag)
                ForEach(vm.availableSpeakers, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .pickerStyle(.menu)

            LabeledContent {
                HStack(spacing: 8) {
                    NeutralSlider(
                        value: Binding(
                            get: { Double(vm.settings.originalMixVolume) },
                            set: { vm.setOriginalMixVolume(Float($0)) }
                        ),
                        in: 0...1
                    )
                    .frame(width: 140)
                    Text("\(Int(vm.settings.originalMixVolume * 100))%")
                        .font(UnisonFonts.mono(11))
                        .tracking(0.44)
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Громкость оригинала")
                    Text("Тихий фон под переводом во время звонка.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Section: Languages

    private var languagesSection: some View {
        Section("Языки по умолчанию") {
            Picker("Я говорю", selection: Binding(
                get: { vm.settings.languagePair.mine },
                set: { newLang in
                    let pair = LanguagePair(mine: newLang, peer: vm.settings.languagePair.peer)
                    vm.setLanguagePair(pair)
                }
            )) {
                ForEach(Language.allCases, id: \.self) { lang in
                    Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
                }
            }
            .pickerStyle(.menu)

            Picker("Слушаю", selection: Binding(
                get: { vm.settings.languagePair.peer },
                set: { newLang in
                    let pair = LanguagePair(mine: vm.settings.languagePair.mine, peer: newLang)
                    vm.setLanguagePair(pair)
                }
            )) {
                ForEach(Language.allCases, id: \.self) { lang in
                    Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Section: OpenAI

    private var openAISection: some View {
        // The API key is a long opaque string (`sk-proj-…` + ~50
        // characters) so cramming it inline next to a "API ключ" label
        // truncates the value to "sk-proj…" which is unreadable. Lay
        // the label above the input and let the field span the full
        // row width — the same trick the system Settings uses for
        // long secrets / paths.
        Section("OpenAI") {
            VStack(alignment: .leading, spacing: 6) {
                Text("API ключ")
                SecretInputBound(
                    text: Binding(
                        get: { vm.apiKey },
                        set: { vm.updateApiKey($0) }
                    ),
                    isVisible: $vm.apiKeyVisible
                )
                .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Text("Хранится в Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    MutedLink("Получить ключ") {
                        onOpenURL(SettingsLinks.openAIKeys)
                    }
                    .accessibilityLabel("Получить ключ OpenAI")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Section: Hotkeys

    private var hotkeysSection: some View {
        Section("Hotkeys") {
            LabeledContent("Старт / стоп") {
                HotkeyRecorder(
                    hotkey: Binding(
                        get: { vm.hotkeyStartStop },
                        set: { vm.updateHotkey(.startStop, $0) }
                    ),
                    isRecording: Binding(
                        get: { vm.recordingHotkey == .startStop },
                        set: { recording in
                            if recording {
                                vm.beginRecordingHotkey(.startStop)
                            } else {
                                vm.cancelRecordingHotkey()
                            }
                        }
                    ),
                    onStartRecording: { onRecordHotkey(.startStop) }
                )
            }
            LabeledContent("Показать транскрипт") {
                HotkeyRecorder(
                    hotkey: Binding(
                        get: { vm.hotkeyShowTranscript },
                        set: { vm.updateHotkey(.showTranscript, $0) }
                    ),
                    isRecording: Binding(
                        get: { vm.recordingHotkey == .showTranscript },
                        set: { recording in
                            if recording {
                                vm.beginRecordingHotkey(.showTranscript)
                            } else {
                                vm.cancelRecordingHotkey()
                            }
                        }
                    ),
                    onStartRecording: { onRecordHotkey(.showTranscript) }
                )
            }
        }
    }

    // MARK: - Section: BlackHole

    private var blackHoleSection: some View {
        Section("BlackHole") {
            LabeledContent("BlackHole 2ch") {
                blackHoleStatusRow(status: vm.blackHole2chStatus)
            }
            LabeledContent("BlackHole 16ch") {
                blackHoleStatusRow(status: vm.blackHole16chStatus)
            }
            LabeledContent {
                InlineButton(
                    vm.isReinstallingBlackHole ? "Установка…" : "Переустановить",
                    icon: Image(systemName: "arrow.clockwise"),
                    variant: .base,
                    isLoading: vm.isReinstallingBlackHole,
                    action: {
                        Task { await vm.reinstallBlackHole() }
                    }
                )
                .disabled(vm.isReinstallingBlackHole)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Виртуальные аудио-устройства")
                    Text("Нужны для перехвата звука с приложений и подачи перевода обратно.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func blackHoleStatusRow(status: BlackHoleStatus) -> some View {
        HStack(spacing: 6) {
            StatusDot(state: statusDotState(for: status), size: 6)
            Text(statusLabel(for: status))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func statusDotState(for status: BlackHoleStatus) -> StatusDot.State {
        switch status {
        case .ready:      .ready
        case .warn:       .warn
        case .error:      .error
        case .installing: .warn
        }
    }

    private func statusLabel(for status: BlackHoleStatus) -> String {
        switch status {
        case .ready:      "установлен"
        case .warn:       "устанавливается…"
        case .error:      "не установлен"
        case .installing: "устанавливается…"
        }
    }

    // MARK: - Section: Behavior

    private var behaviorSection: some View {
        Section("Поведение") {
            Toggle("Запускать при логине", isOn: Binding(
                get: { vm.autostart },
                set: { vm.updateAutostart($0) }
            ))
            .controlSize(.mini)
            Toggle("Скрывать меню при старте сессии", isOn: Binding(
                get: { vm.hideMenuOnSession },
                set: { vm.updateHideMenuOnSession($0) }
            ))
            .controlSize(.mini)
        }
    }

    // MARK: - Section: About

    private var aboutSection: some View {
        Section("О приложении") {
            LabeledContent("Версия") {
                HStack(spacing: 4) {
                    Text("1.0.0")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("· build 42")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Лицензия") {
                aboutLink("MIT", url: SettingsLinks.license)
            }
            LabeledContent("Исходный код") {
                aboutLink("github.com/unison", url: SettingsLinks.source)
            }
        }
    }

    private func aboutLink(_ text: String, url: URL) -> some View {
        MutedLink(text) {
            onOpenURL(url)
        }
    }
}

// MARK: - SecretInput bound variant

/// Wrapper around `SecretInput` that lets the parent control the
/// "visible" state — Settings binds it through the view-model so
/// the toggle survives across opens. The base component owns the
/// flag internally, which is fine in onboarding; for Settings we
/// override it.
private struct SecretInputBound: View {
    @Binding var text: String
    @Binding var isVisible: Bool

    var body: some View {
        // `SecretInput` already shows a tappable visibility toggle.
        // For now we reuse it directly — its internal `isVisible`
        // state defaults to `false`, matching the design's initial
        // password mode. The VM-level `apiKeyVisible` is kept in
        // sync via the toggle button there if/when we hook it up.
        SecretInput(text: $text, placeholder: "sk-proj-…")
    }
}

// MARK: - Layout constants

private enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    static let windowHeight: CGFloat = 540
}

// MARK: - External URLs

private enum SettingsLinks {
    static let openAIKeys = URL(string: "https://platform.openai.com/api-keys")!
    static let license = URL(string: "https://opensource.org/licenses/MIT")!
    static let source = URL(string: "https://github.com")!
}
