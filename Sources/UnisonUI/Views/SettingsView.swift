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

    /// Read from `Info.plist` once at view-construction. The previous
    /// version of the About section hardcoded "1.0.0 · build 42",
    /// which drifts the moment the bundle ships a real version (and
    /// also disagrees with DiagnosticCollector, which DOES read the
    /// bundle). Fall back to a non-zero default so previews and unit
    /// tests outside an .app bundle still render something.
    fileprivate static let bundleShortVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }()
    fileprivate static let bundleBuild: String = {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }()

    /// Caller-provided URL opener (license, GitHub, OpenAI keys page).
    let onOpenURL: (URL) -> Void

    /// Host hook for hotkey recording. The host begins a local
    /// `NSEvent` monitor; when it captures a key combo it calls
    /// `vm.updateHotkey(...)` directly. This view only signals which
    /// row was tapped via `vm.beginRecordingHotkey(_:)`.
    let onRecordHotkey: (HotkeyKind) -> Void

    /// Closes the Settings window. Wired by `SettingsWindowController`
    /// in the host app — when running in previews this stays the
    /// default no-op.
    let onClose: () -> Void

    public init(
        vm: SettingsViewModel,
        onOpenURL: @escaping (URL) -> Void = { _ in },
        onRecordHotkey: @escaping (HotkeyKind) -> Void = { _ in },
        onClose: @escaping () -> Void = {}
    ) {
        self.vm = vm
        self.onOpenURL = onOpenURL
        self.onRecordHotkey = onRecordHotkey
        self.onClose = onClose
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
        // ScrollView + custom transparent cards instead of `Form { ...
        // }.formStyle(.grouped)`. Reason: on macOS 26, the system
        // grouped-form style renders each `Section` as an opaque
        // material card that sits on top of `NSVisualEffectView` —
        // the user sees a solid grey panel even with
        // `.scrollContentBackground(.hidden)` applied to the Form
        // (that modifier only clears the outer scroll background,
        // not the per-section materials). The user's report was:
        // "до сих пор не прозрачно. Полностью серый фон".
        //
        // Replacing Form with ScrollView + a `card(...)` helper that
        // uses a fully transparent (or very-faintly-tinted)
        // background lets the host window's `NSVisualEffectView`
        // show through. Each card retains a thin hairline border
        // for visual grouping so rows don't look unmoored.
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 18) {
                audioSection
                languagesSection
                openAISection
                hotkeysSection
                blackHoleSection
                behaviorSection
                aboutSection
                howToUseSection
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .frame(minWidth: SettingsLayout.windowWidth, minHeight: SettingsLayout.minWindowHeight)
        // The host window uses `.fullSizeContentView` + hidden traffic
        // lights so the SwiftUI surface extends edge-to-edge in the
        // rounded Liquid Glass card. The header overlay carries the
        // close button + drag area.
        .safeAreaInset(edge: .top, spacing: 0) {
            settingsHeader
        }
        // `.overlay` puts the SaveIndicator *above* the content rather
        // than inserting it into the layout flow. Two consequences:
        //   1. Showing/hiding the indicator never shifts the rows
        //      (the user reported jumping with `.safeAreaInset`).
        //   2. The indicator floats over the content regardless of
        //      scroll position, so it stays visible at any scroll.
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

    // MARK: - Title bar (custom — window chrome is hidden)

    /// Mini header: app subtitle on the left, close button on the
    /// right. Replaces the system titlebar (hidden in
    /// `SettingsWindowController` to make the window a clean Liquid
    /// Glass card). Transparent background so the visual effect
    /// material shows through.
    private var settingsHeader: some View {
        HStack {
            Text("Настройки")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.leading, 18)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(UnisonColors.whiteAlpha(0.08))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, 12)
            .keyboardShortcut("w", modifiers: .command)
        }
        .frame(height: 36)
        // Transparent — let the NSVisualEffectView underneath show.
        .background(Color.clear)
    }

    // MARK: - Section card helper

    /// Section container used in place of the system grouped-Form
    /// `Section`. Renders the title above a card whose background is
    /// nearly transparent (`whiteAlpha 0.04`) — just enough to give
    /// the rows visual grouping without obscuring the host window's
    /// Liquid Glass material. Inner rows use the same `VStack`
    /// spacing as the previous Form layout so existing content
    /// (`LabeledContent`, `Picker`, `Toggle`) reads identically.
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

                Text("Ваш реальный микрофон. В Zoom выберите «BlackHole 2ch» как mic.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
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

                Text("Куда играть перевод. Системный output должен быть «BlackHole 16ch».")
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
        card(title: "Языки по умолчанию") {
            // Restrict to the 13 supported output targets — both sides
            // of `LanguagePair` get sent as `session.audio.output.language`
            // (peer-incoming stream targets `.mine`, me-outgoing targets
            // `.peer`), so neither slot may carry a non-target language.
            Picker("Я говорю", selection: Binding(
                get: { vm.settings.languagePair.mine },
                set: { newLang in
                    let pair = LanguagePair(mine: newLang, peer: vm.settings.languagePair.peer)
                    vm.setLanguagePair(pair)
                }
            )) {
                ForEach(Language.supportedTargets, id: \.self) { lang in
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
                ForEach(Language.supportedTargets, id: \.self) { lang in
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
        card(title: "OpenAI") {
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
        card(title: "BlackHole") {
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
        card(title: "Поведение") {
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

    // MARK: - Section: How to use

    /// "Как пользоваться" — final section at the bottom of Settings.
    /// Explains the Two-BlackHole architecture so users understand
    /// which device to pick where in their calling app.
    private var howToUseSection: some View {
        card(title: "Как пользоваться") {
            flowDiagramRow
            zoomSetupRow
            launchStepsRow
        }
    }

    /// Sub-row A — bidirectional flow diagram built from SF Symbols.
    /// Two rows of compact icon+caption cells separated by arrows.
    private var flowDiagramRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Поток звука")
                .font(.subheadline.weight(.medium))

            VStack(alignment: .leading, spacing: 12) {
                // Outgoing: real mic → Unison → BlackHole 2ch → Zoom mic.
                HStack(spacing: 6) {
                    flowItem(icon: "mic.fill", label: "Ваш\nмикрофон")
                    flowArrow
                    flowItem(icon: "waveform.path.ecg", label: "Unison\nперевод")
                    flowArrow
                    flowItem(icon: "speaker.wave.2.fill", label: "BlackHole\n2ch")
                    flowArrow
                    flowItem(icon: "phone.fill", label: "Zoom\nmic")
                }

                // Incoming: Zoom audio → BlackHole 16ch → Unison → headphones.
                HStack(spacing: 6) {
                    flowItem(icon: "phone.fill", label: "Zoom\naudio")
                    flowArrow
                    flowItem(icon: "speaker.wave.2.fill", label: "BlackHole\n16ch")
                    flowArrow
                    flowItem(icon: "waveform.path.ecg", label: "Unison\nперевод")
                    flowArrow
                    flowItem(icon: "speaker.wave.3.fill", label: "Ваши\nнаушники")
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// One cell in the flow diagram: 24-pt SF Symbol + 2-line 11-pt label.
    private func flowItem(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    /// Small separator arrow between flow cells.
    private var flowArrow: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.tertiary)
    }

    /// Sub-row B — numbered Zoom/Meet setup checklist.
    private var zoomSetupRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Настройка Zoom / Meet")
                .font(.subheadline.weight(.medium))
            stepRow(index: 1, text: "Откройте настройки звука в Zoom (или Google Meet, Discord и т. д.)")
            stepRow(index: 2, text: "Микрофон → BlackHole 2ch")
            stepRow(index: 3, text: "Динамик → System Default или BlackHole 16ch")
            stepRow(index: 4, text: "В Системных настройках macOS выход → BlackHole 16ch")
        }
        .padding(.vertical, 4)
    }

    /// Sub-row C — final launch checklist after setup.
    private var launchStepsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Запуск")
                .font(.subheadline.weight(.medium))
            stepRow(index: 1, text: "Выберите выше ваш реальный микрофон и динамик")
            stepRow(index: 2, text: "В popover на menubar выберите языки")
            stepRow(index: 3, text: "Нажмите «Начать перевод»")
        }
        .padding(.vertical, 4)
    }

    /// One numbered step row used by both setup checklists.
    /// Renders a circled monospace digit + the instruction text.
    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(index).")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
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
    /// Lower bound for the form's intrinsic height. The window itself
    /// opens at 620pt (the standard macOS Settings pane height) and
    /// the user can resize it; the form's native scroll view handles
    /// overflow when the window is shorter than the full content
    /// stack.
    static let minWindowHeight: CGFloat = 480
}

// MARK: - External URLs

private enum SettingsLinks {
    static let openAIKeys = URL(string: "https://platform.openai.com/api-keys")!
    static let license = URL(string: "https://opensource.org/licenses/MIT")!
    // Repo URL — previously pointed at github.com root, which was a
    // dead-end placeholder. The label below this link reads
    // "github.com/unison" but the destination has to match the *real*
    // repo to be useful. Update if the canonical home moves.
    static let source = URL(string: "https://github.com/NIK-TIGER-BILL/unison")!
}
