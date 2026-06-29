import SwiftUI
import UnisonAudio
import UnisonDomain

/// Settings window — single-column scrolling list of section cards.
/// `UnisonUI` can't import AppKit, so URL opening and hotkey
/// recording go through closures supplied by the host.
public struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    fileprivate static let bundleShortVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()
    fileprivate static let bundleBuild: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }()

    let onOpenURL: (URL) -> Void
    let onRecordHotkey: (HotkeyKind) -> Void
    /// Fired when the user cancels an in-flight hotkey recording from
    /// the UI (clicking the recording chip again). The host must tear
    /// down its NSEvent monitor — clearing only the VM state would
    /// leave the monitor swallowing keystrokes app-wide.
    let onCancelRecordHotkey: () -> Void

    public init(
        vm: SettingsViewModel,
        onOpenURL: @escaping (URL) -> Void = { _ in },
        onRecordHotkey: @escaping (HotkeyKind) -> Void = { _ in },
        onCancelRecordHotkey: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenURL = onOpenURL
        self.onRecordHotkey = onRecordHotkey
        self.onCancelRecordHotkey = onCancelRecordHotkey
    }

    /// `Picker` needs a non-optional tag — reserve empty string as
    /// "system default" and map back to `nil` in the setter.
    private static let defaultDeviceTag = ""

    @SwiftUI.State private var saveIndicator = SaveIndicatorController()

    public var body: some View {
        // `Form { }.formStyle(.grouped)` was the obvious choice but
        // on macOS 26 it renders each Section as an opaque vibrancy
        // card that hides the host window's glass even with
        // `.scrollContentBackground(.hidden)`. Plain ScrollView + a
        // transparent `card(...)` helper lets the window glass show
        // through.
        ScrollView(.vertical) {
            // Eager VStack, not Lazy — there are only ~8 sections.
            // Lazy layout resized the scrollbar thumb mid-scroll.
            VStack(alignment: .leading, spacing: 18) {
                audioSection
                appScopeSection
                languagesSection
                modelSection
                hotkeysSection
                blackHoleSection
                behaviorSection
                aboutSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        // Hard cutoff at the safe-area top so scrolling rows don't
        // bleed into the transparent system titlebar.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .frame(minWidth: SettingsLayout.windowWidth, minHeight: SettingsLayout.minWindowHeight)
        // Floating SaveIndicator — `.overlay` keeps it off the layout
        // flow so showing/hiding doesn't shift rows underneath.
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

    // MARK: - Section card helper

    @ViewBuilder
    private func card<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Spread label / content to opposite edges of each row —
            // the default `LabeledContent` style packs them adjacent.
            .labeledContentStyle(SpreadLabeledStyle())
            .toggleStyle(.switch)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(UnisonColors.whiteAlpha(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(UnisonColors.whiteAlpha(0.08), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Section: Audio

    private var audioSection: some View {
        card(title: "Аудио") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Микрофон") {
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
                    .labelsHidden()
                }

                Text("Ваш реальный микрофон. В Zoom выберите «BlackHole 2ch» как mic.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Динамик") {
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
                    .labelsHidden()
                }

                Text("Куда играть перевод.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

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
                    Text("\(Int((vm.settings.originalMixVolume * 100).rounded()))%")
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

    // MARK: - Section: Languages

    private var languagesSection: some View {
        card(title: "Языки по умолчанию") {
            LabeledContent("Я говорю") {
                Picker("Я говорю", selection: Binding(
                    get: { vm.settings.languagePair.mine },
                    set: { newLang in
                        let pair = LanguagePair(mine: newLang, peer: vm.settings.languagePair.peer)
                        vm.setLanguagePair(pair)
                    }
                )) {
                    ForEach(vm.settings.translationModel.supportedTargets, id: \.self) { lang in
                        Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            LabeledContent("Слушаю") {
                Picker("Слушаю", selection: Binding(
                    get: { vm.settings.languagePair.peer },
                    set: { newLang in
                        let pair = LanguagePair(mine: vm.settings.languagePair.mine, peer: newLang)
                        vm.setLanguagePair(pair)
                    }
                )) {
                    ForEach(vm.settings.translationModel.supportedTargets, id: \.self) { lang in
                        Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Section: Translation model

    private var modelSection: some View {
        // Label above the input rather than inline — long API keys
        // can't share a row without truncation.
        card(title: "Модель перевода") {
            LabeledContent("Движок") {
                Picker("Движок", selection: Binding(
                    get: { vm.settings.translationModel },
                    set: { vm.setTranslationModel($0) }
                )) {
                    ForEach(TranslationModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("API ключ")
                SecretInputBound(
                    text: Binding(
                        get: { vm.apiKey },
                        set: { vm.updateApiKey($0) }
                    ),
                    placeholder: vm.settings.translationModel.apiKeyPlaceholder
                )
                .frame(maxWidth: .infinity)
                HStack(spacing: 6) {
                    Text("Хранится в Keychain.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    MutedLink("Получить ключ") {
                        onOpenURL(vm.settings.translationModel.getKeyURL)
                    }
                    .accessibilityLabel("Получить ключ \(vm.settings.translationModel.displayName)")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Section: Hotkeys

    private var hotkeysSection: some View {
        card(title: "Хоткеи") {
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
                                onCancelRecordHotkey()
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
                                onCancelRecordHotkey()
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
        card(title: "BlackHole") {
            LabeledContent("BlackHole 2ch") {
                blackHoleStatusRow(status: vm.blackHole2chStatus)
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
        card(title: "Поведение") {
            // Wrap each Toggle in `LabeledContent` so the card's
            // `SpreadLabeledStyle` pushes the switch to the trailing
            // edge — naked `Toggle("…", isOn:)` packs label+switch
            // adjacent outside Form.
            LabeledContent("Запускать при логине") {
                Toggle("Запускать при логине", isOn: Binding(
                    get: { vm.autostart },
                    set: { vm.updateAutostart($0) }
                ))
                .labelsHidden()
            }
            LabeledContent("Скрывать меню при старте сессии") {
                Toggle("Скрывать меню при старте сессии", isOn: Binding(
                    get: { vm.hideMenuOnSession },
                    set: { vm.updateHideMenuOnSession($0) }
                ))
                .labelsHidden()
            }
        }
    }

    // MARK: - Section: About

    private var aboutSection: some View {
        card(title: "О приложении") {
            LabeledContent("Версия") {
                HStack(spacing: 4) {
                    Text(Self.bundleShortVersion)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("· build \(Self.bundleBuild)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Лицензия") {
                aboutLink("MIT", url: SettingsLinks.license)
            }
            LabeledContent("Исходный код") {
                aboutLink("GitHub", url: SettingsLinks.source)
            }
        }
    }

    private func aboutLink(_ text: String, url: URL) -> some View {
        MutedLink(text) {
            onOpenURL(url)
        }
    }

}

private struct SecretInputBound: View {
    @Binding var text: String
    var placeholder: String = "sk-proj-…"

    var body: some View {
        // Show/hide toggle lives inside `SecretInput` (internal state).
        SecretInput(text: $text, placeholder: placeholder)
    }
}

private enum SettingsLayout {
    static let windowWidth: CGFloat = 560
    static let minWindowHeight: CGFloat = 480
}

private enum SettingsLinks {
    static let license = URL(string: "https://opensource.org/licenses/MIT")!
    static let source = URL(string: "https://github.com/NIK-TIGER-BILL/unison")!
}

/// Pushes the label to the leading edge and the content to the
/// trailing edge of each row — restores the visual contract `Form { }`
/// provided automatically before the Form → ScrollView refactor.
private struct SpreadLabeledStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
            Spacer(minLength: 8)
            configuration.content
        }
        .frame(maxWidth: .infinity)
    }
}
