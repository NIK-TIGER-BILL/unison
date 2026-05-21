import SwiftUI
import UnisonDomain

/// Settings window — single-column scrollable, auto-saving, glass-on-aurora.
///
/// Strictly mirrors `design/settings-final/index.html`:
/// - 560pt wide, 32pt title bar, `.content-scroll` 540pt max height.
/// - Sections: Аудио / Языки / OpenAI / Hotkeys / BlackHole / Поведение /
///   О приложении. `SectionHeader` separates them.
/// - Each row uses `SettingsRow` (`.row` in CSS) — label/icon on the left,
///   trailing value control on the right, optional `row-hint` underneath.
/// - Dropdowns (mic / speaker / lang-mine / lang-peer) open as portal-style
///   pickers anchored beneath the trigger button.
/// - All edits auto-save via `vm.update…(_:)` setters; the title bar's
///   `SaveIndicator` flashes whenever `lastSavedAt` advances.
/// - BlackHole "Переустановить" delegates to `vm.reinstallBlackHole()` which
///   flips both status dots to warn while installing, then resyncs from the
///   device registry.
///
/// `UnisonUI` cannot import `AppKit`, so any system action (opening a URL,
/// starting a global hotkey monitor) goes through the closures the host
/// supplies:
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

    // MARK: - Local state

    /// Which dropdown is currently open (mic / speaker / langMine /
    /// langPeer). Only one can be open at a time. `nil` means none.
    @SwiftUI.State private var openDropdown: DropdownKind? = nil

    /// Anchors for each dropdown trigger, captured via `PreferenceKey`
    /// so the floating panel knows where to render itself.
    @SwiftUI.State private var triggerAnchors: [DropdownKind: CGRect] = [:]

    /// Save-indicator controller — flashes "✓ сохранено" for ~1.6s
    /// whenever the VM bumps `lastSavedAt`.
    @SwiftUI.State private var saveIndicator = SaveIndicatorController()

    enum DropdownKind: Hashable {
        case microphone
        case speaker
        case langMine
        case langPeer
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            // Aurora glass floor — visible through the window's
            // transparent chrome (the controller sets the NSWindow's
            // background to clear). Matches `design/settings-final/`.
            AuroraBackground()

            window
                .frame(width: SettingsLayout.windowWidth)

            if let kind = openDropdown {
                dropdownOverlay(for: kind)
                    .zIndex(20)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: SettingsLayout.windowWidth, height: SettingsLayout.windowHeight)
        .coordinateSpace(name: SettingsLayout.coordinateSpace)
        .onPreferenceChange(TriggerAnchorKey.self) { dict in
            triggerAnchors = dict
        }
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { closeDropdown() }
        )
        .onChange(of: vm.lastSavedAt) { _, _ in
            saveIndicator.markSaved()
        }
        .animation(UnisonAnimations.dropdown, value: openDropdown)
    }

    // MARK: - Window chrome

    private var window: some View {
        VStack(spacing: 0) {
            titlebar
            ScrollView {
                VStack(spacing: 0) {
                    audioSection
                    languagesSection
                    openAISection
                    hotkeysSection
                    blackHoleSection
                    behaviorSection
                    aboutSection
                }
                .padding(.bottom, 6)
            }
            .scrollIndicators(.hidden)
        }
        // Glass chrome: dark tint over the Aurora floor, hairline border,
        // top specular highlight. Skips `.regularMaterial` so the Aurora
        // gradients remain visible through the window — matches the design
        // HTML's `backdrop-filter: blur` semi-transparent surface. The
        // real `NSVisualEffectView` blur is wired by the window controller.
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 20 / 255, green: 22 / 255, blue: 30 / 255).opacity(0.55))
                LinearGradient(
                    colors: [UnisonColors.whiteAlpha(0.16), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .blendMode(.screen)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(UnisonColors.whiteAlpha(0.13), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.5), radius: 18, x: 0, y: 16)
    }

    /// Custom title bar — the real `NSWindow` traffic lights live in
    /// the controller layer (`SettingsWindowController` makes them
    /// visible and functional). We render the title text and the
    /// `SaveIndicator` here to match the design's full-width 32pt bar.
    private var titlebar: some View {
        HStack(spacing: 8) {
            // Spacer to clear the native traffic lights (left ~74pt).
            Color.clear.frame(width: 64, height: 1)
            Text("Unison · Настройки")
                .font(.system(size: 12.5, weight: .medium))
                .tracking(-0.06)
                .foregroundStyle(UnisonColors.whiteAlpha(0.85))
            Spacer()
            SaveIndicator(isShown: Binding(
                get: { saveIndicator.isShown },
                set: { saveIndicator.isShown = $0 }
            ))
            .padding(.trailing, 14)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(UnisonColors.whiteAlpha(0.07))
                .frame(height: 0.5)
        }
    }

    // MARK: - Section: Audio

    private var audioSection: some View {
        Group {
            SectionHeader("Аудио")
            SettingsRow(
                "Микрофон",
                icon: Image(systemName: "mic")
            ) {
                dropdownTrigger(
                    kind: .microphone,
                    label: currentMicLabel
                )
            }
            SettingsRow(
                "Динамик",
                icon: Image(systemName: "speaker.wave.2.fill")
            ) {
                dropdownTrigger(
                    kind: .speaker,
                    label: currentSpeakerLabel
                )
            }
            SettingsRow(
                "Громкость оригинала",
                hint: "Тихий фон под переводом во время звонка."
            ) {
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
                        .foregroundStyle(UnisonColors.whiteAlpha(0.55))
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - Section: Languages

    private var languagesSection: some View {
        Group {
            SectionHeader("Языки по умолчанию")
            SettingsRow("Я говорю") {
                dropdownTrigger(
                    kind: .langMine,
                    label: vm.settings.languagePair.mine.displayName
                )
            }
            SettingsRow("Слушаю") {
                dropdownTrigger(
                    kind: .langPeer,
                    label: vm.settings.languagePair.peer.displayName
                )
            }
        }
    }

    // MARK: - Section: OpenAI

    private var openAISection: some View {
        Group {
            SectionHeader("OpenAI")
            SettingsRow(
                "API ключ",
                icon: Image(systemName: "key.fill"),
                hint: nil
            ) {
                SecretInputBound(
                    text: Binding(
                        get: { vm.apiKey },
                        set: { vm.updateApiKey($0) }
                    ),
                    isVisible: $vm.apiKeyVisible
                )
                .frame(width: 220)
            }
            // The "Получить ключ ↗" link is part of the hint slot per design.
            HStack(spacing: 0) {
                Spacer().frame(width: 16)
                Text("Хранится в Keychain.")
                    .font(.system(size: 11))
                    .foregroundStyle(UnisonColors.whiteAlpha(0.45))
                MutedLink("Получить ключ") {
                    onOpenURL(SettingsLinks.openAIKeys)
                }
                .accessibilityLabel("Получить ключ OpenAI")
                Spacer(minLength: 0)
            }
            .padding(.bottom, 8)
            .padding(.top, -6)
        }
    }

    // MARK: - Section: Hotkeys

    private var hotkeysSection: some View {
        Group {
            SectionHeader("Hotkeys")
            SettingsRow(
                "Старт / стоп",
                icon: Image(systemName: "command")
            ) {
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
            SettingsRow(
                "Показать транскрипт",
                icon: Image(systemName: "command")
            ) {
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
        Group {
            SectionHeader("BlackHole")
            SettingsRow("BlackHole 2ch") {
                blackHoleStatusRow(status: vm.blackHole2chStatus)
            }
            SettingsRow("BlackHole 16ch") {
                blackHoleStatusRow(status: vm.blackHole16chStatus)
            }
            SettingsRow(
                "Виртуальные аудио-устройства",
                hint: "Нужны для перехвата звука с приложений и подачи перевода обратно."
            ) {
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
            }
        }
    }

    private func blackHoleStatusRow(status: BlackHoleStatus) -> some View {
        HStack(spacing: 6) {
            StatusDot(state: statusDotState(for: status), size: 6)
            Text(statusLabel(for: status))
                .font(.system(size: 12))
                .foregroundStyle(UnisonColors.whiteAlpha(0.55))
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
        Group {
            SectionHeader("Поведение")
            SettingsRow("Запускать при логине") {
                PillToggle(isOn: Binding(
                    get: { vm.autostart },
                    set: { vm.updateAutostart($0) }
                ))
            }
            SettingsRow("Скрывать меню при старте сессии") {
                PillToggle(isOn: Binding(
                    get: { vm.hideMenuOnSession },
                    set: { vm.updateHideMenuOnSession($0) }
                ))
            }
        }
    }

    // MARK: - Section: About

    private var aboutSection: some View {
        Group {
            SectionHeader("О приложении")
            SettingsRow("Версия") {
                HStack(spacing: 4) {
                    Text("1.0.0")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.88))
                    Text("· build 42")
                        .font(.system(size: 11.5))
                        .foregroundStyle(UnisonColors.whiteAlpha(0.55))
                }
            }
            SettingsRow("Лицензия") {
                aboutLink("MIT", url: SettingsLinks.license)
            }
            SettingsRow("Исходный код") {
                aboutLink("github.com/unison", url: SettingsLinks.source)
            }
        }
    }

    private func aboutLink(_ text: String, url: URL) -> some View {
        MutedLink(text) {
            onOpenURL(url)
        }
    }

    // MARK: - Dropdown trigger (chip)

    @ViewBuilder
    private func dropdownTrigger(kind: DropdownKind, label: String) -> some View {
        let isOpen = (openDropdown == kind)
        Button {
            withAnimation(UnisonAnimations.dropdown) {
                openDropdown = isOpen ? nil : kind
            }
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(isOpen ? .white : UnisonColors.whiteAlpha(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isOpen
                        ? UnisonColors.whiteAlpha(0.85)
                        : UnisonColors.whiteAlpha(0.55))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 9)
            .frame(maxWidth: 200, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(UnisonColors.whiteAlpha(isOpen ? 0.10 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        UnisonColors.whiteAlpha(isOpen ? 0.22 : 0.10),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TriggerAnchorKey.self,
                    value: [kind: proxy.frame(in: .named(SettingsLayout.coordinateSpace))]
                )
            }
        )
    }

    // MARK: - Dropdown overlay

    @ViewBuilder
    private func dropdownOverlay(for kind: DropdownKind) -> some View {
        let anchor = triggerAnchors[kind] ?? .zero
        let dropdownWidth: CGFloat = 220
        let originX = min(
            max(8, anchor.maxX - dropdownWidth),
            SettingsLayout.windowWidth - dropdownWidth - 8
        )
        let originY = anchor.maxY + 6

        Group {
            switch kind {
            case .microphone:
                deviceDropdown(
                    devices: vm.availableMics,
                    selectedUID: vm.settings.inputDeviceUID,
                    onPick: { uid in
                        vm.setInputDeviceUID(uid)
                        closeDropdown()
                    },
                    onCancel: { closeDropdown() }
                )
            case .speaker:
                deviceDropdown(
                    devices: vm.availableSpeakers,
                    selectedUID: vm.settings.outputDeviceUID,
                    onPick: { uid in
                        vm.setOutputDeviceUID(uid)
                        closeDropdown()
                    },
                    onCancel: { closeDropdown() }
                )
            case .langMine:
                LanguagePickerDropdown(
                    selection: Binding(
                        get: { vm.settings.languagePair.mine },
                        set: { newLang in
                            let pair = LanguagePair(mine: newLang, peer: vm.settings.languagePair.peer)
                            vm.setLanguagePair(pair)
                        }
                    ),
                    onPick: { newLang in
                        let pair = LanguagePair(mine: newLang, peer: vm.settings.languagePair.peer)
                        vm.setLanguagePair(pair)
                        closeDropdown()
                    },
                    onCancel: { closeDropdown() }
                )
            case .langPeer:
                LanguagePickerDropdown(
                    selection: Binding(
                        get: { vm.settings.languagePair.peer },
                        set: { newLang in
                            let pair = LanguagePair(mine: vm.settings.languagePair.mine, peer: newLang)
                            vm.setLanguagePair(pair)
                        }
                    ),
                    onPick: { newLang in
                        let pair = LanguagePair(mine: vm.settings.languagePair.mine, peer: newLang)
                        vm.setLanguagePair(pair)
                        closeDropdown()
                    },
                    onCancel: { closeDropdown() }
                )
            }
        }
        .offset(x: originX, y: originY)
    }

    private func deviceDropdown(
        devices: [AudioDevice],
        selectedUID: String?,
        onPick: @escaping (String?) -> Void,
        onCancel: @escaping () -> Void
    ) -> some View {
        DeviceDropdown(
            devices: devices,
            selectedUID: selectedUID,
            onPick: onPick,
            onCancel: onCancel
        )
    }

    // MARK: - Helpers

    private func closeDropdown() {
        if openDropdown != nil {
            withAnimation(UnisonAnimations.dropdown) {
                openDropdown = nil
            }
        }
    }

    private var currentMicLabel: String {
        guard let uid = vm.settings.inputDeviceUID,
              let match = vm.availableMics.first(where: { $0.uid == uid }) else {
            return "По умолчанию"
        }
        return match.name
    }

    private var currentSpeakerLabel: String {
        guard let uid = vm.settings.outputDeviceUID,
              let match = vm.availableSpeakers.first(where: { $0.uid == uid }) else {
            return "По умолчанию"
        }
        return match.name
    }
}

// MARK: - Device dropdown

/// Audio-device picker — same visual language as `LanguagePickerDropdown`,
/// but operates on `[AudioDevice]` and exposes the "По умолчанию" item
/// that maps to a `nil` UID. Lives in this file because no other view
/// needs it.
private struct DeviceDropdown: View {
    let devices: [AudioDevice]
    let selectedUID: String?
    let onPick: (String?) -> Void
    let onCancel: () -> Void

    @SwiftUI.State private var query: String = ""

    private var filtered: [AudioDevice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return devices }
        let needle = trimmed.lowercased()
        return devices.filter { $0.name.lowercased().contains(needle) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if devices.count > 6 {
                SearchField(text: $query)
                    .padding(.bottom, 6)
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    defaultRow
                    if filtered.isEmpty && !query.isEmpty {
                        Text("Ничего не найдено")
                            .font(.system(size: 12))
                            .foregroundStyle(UnisonColors.whiteAlpha(0.4))
                            .padding(.vertical, 14)
                    } else {
                        ForEach(filtered, id: \.uid) { device in
                            row(for: device)
                                .onTapGesture { onPick(device.uid) }
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
        }
        .padding(5)
        .liquidGlass(cornerRadius: 13)
        .frame(width: 220)
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }

    private var defaultRow: some View {
        let isSelected = (selectedUID == nil)
        return HStack(spacing: 9) {
            Image(systemName: "circle.dotted")
                .font(.system(size: 11))
                .foregroundStyle(UnisonColors.whiteAlpha(0.55))
            Text("По умолчанию")
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : UnisonColors.whiteAlpha(0.85))
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onPick(nil) }
    }

    private func row(for device: AudioDevice) -> some View {
        let isSelected = device.uid == selectedUID
        return HStack(spacing: 9) {
            Text(device.name)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : UnisonColors.whiteAlpha(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.clear)
        )
        .contentShape(Rectangle())
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
    static let coordinateSpace: String = "settings"
}

// MARK: - External URLs

private enum SettingsLinks {
    static let openAIKeys = URL(string: "https://platform.openai.com/api-keys")!
    static let license = URL(string: "https://opensource.org/licenses/MIT")!
    static let source = URL(string: "https://github.com")!
}

// MARK: - PreferenceKey

/// Captures the screen-space frame of each dropdown trigger so the
/// floating dropdown overlay can position itself. Multiple triggers
/// emit values keyed by `DropdownKind`; the reducer merges them.
private struct TriggerAnchorKey: PreferenceKey {
    static let defaultValue: [SettingsView.DropdownKind: CGRect] = [:]
    static func reduce(
        value: inout [SettingsView.DropdownKind: CGRect],
        nextValue: () -> [SettingsView.DropdownKind: CGRect]
    ) {
        let next = nextValue()
        for (k, v) in next { value[k] = v }
    }
}
