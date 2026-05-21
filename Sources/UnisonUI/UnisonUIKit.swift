import Foundation

/// # Unison UI Kit
///
/// Index of every public design-system surface in `UnisonUI`. The kit is
/// strictly SwiftUI — it must not import `AppKit`. Anything that needs to
/// talk to the system (window management, URL opening, `NSEvent` monitors)
/// is exposed as a closure or callback that the host (`UnisonApp`) wires up.
///
/// This file is documentation only — there is no executable surface here.
/// Use it as the canonical map when adding a new screen or component.
///
/// ## Design tokens
///
/// **`UnisonColors`** (`Design/Colors.swift`)
/// - `pageBg` — `#08080a` base background for design pages and aurora floor.
/// - `pageFg` — `#f5f5f7` primary foreground text.
/// - `pageMute` — `#8e8e93` muted / secondary text.
/// - `ready` — `#58e09a` OK / toggle-on green.
/// - `active` — `#5ac8fa` translating / pulse blue.
/// - `warn` — `#ffc060` validation warning amber.
/// - `stop` — `#ff6e82` destructive button core.
/// - `error` — `#ff7a8c` error state.
/// - `coralTop` / `coralBottom` — coral destructive-gradient stops.
/// - `whiteAlpha(_:)` — neutral-tint helper used everywhere instead of accent.
///
/// **`UnisonFonts`** (`Design/Fonts.swift`)
/// - `uiTitle(_:)` — DM Sans light, default 18pt.
/// - `uiBody(_:)` — DM Sans regular, default 13pt.
/// - `mono(_:)` — IBM Plex Mono caption, default 11pt.
/// - `sectionHead()` — caps section label, 10pt monospaced.
///
/// **`UnisonSpacing`** (`Design/Spacing.swift`) — 4-base grid.
/// - `xs=4`, `s=8`, `m=12`, `l=16`, `xl=24`.
///
/// **`UnisonAnimations`** (`Design/AnimationTokens.swift`)
/// - `glassAppear`, `bubbleIn`, `pulseAnimation`, `state`, `hover`, `press`, `dropdown`.
///
/// ## Design primitives
///
/// - **`LiquidGlassPanel`** + `View.liquidGlass(cornerRadius:)` — thin
///   wrapper around Apple's native `glassEffect(.regular, in:)` (macOS 26+).
///   Respects `\.accessibilityReduceTransparency`.
/// - **`AuroraBackground`** + `View.auroraBackground()` — three-layer aurora
///   gradient used behind onboarding/settings/transcript windows.
/// - **`UnisonLogoShape`** — `Shape` rendering the parametric Unison logo.
///
/// ## Components
///
/// Every component below is `public` and lives under `Components/`.
///
/// ### Status & feedback
///
/// - **`StatusDot`** — colored pulsing status dot.
///   `init(state: StatusDot.State, size: CGFloat = 7, pulse: Bool? = nil)`
///   `// StatusDot(state: .active)`
///
/// - **`Spinner`** — indeterminate 70% arc spinner (0.85s/turn).
///   `init(size: CGFloat = 12, lineWidth: CGFloat = 1.5, color: Color = .white)`
///   `// Spinner(size: 10, lineWidth: 1.3)`
///
/// - **`SaveIndicator`** (+ `SaveIndicatorController`) — "✓ сохранено" toast
///   for Settings; auto-fades after 1.6s.
///   `init(isShown: Binding<Bool>)`
///   `// SaveIndicator(isShown: $controller.isShown)`
///
/// - **`WarnRow`** — amber inline warning row.
///   `init(message: String, isVisible: Bool = true)`
///   `// WarnRow(message: "Выбран одинаковый язык")`
///
/// - **`ErrorRow`** — coral inline error row with optional retry / open-settings.
///   `init(title: String, detail: String? = nil, action: ErrorRow.Action? = nil)`
///   `// ErrorRow(title: "Доступ запрещён", action: .openSettings(label: "Открыть", handler: open))`
///
/// ### Buttons & links
///
/// - **`IconButton`** — circular icon button using native
///   `.buttonStyle(.glass)` + `.buttonBorderShape(.circle)`.
///   `init(size: CGFloat = 28, cornerRadius: CGFloat = 7, action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon)`
///   `// IconButton(action: open) { Image(systemName: "gear") }`
///
/// - **`PrimaryGlassButton`** — full-width primary action using
///   `.buttonStyle(.glassProminent)`; `.standard` / `.destructive` switches
///   the tint between neutral and Liquid-Glass-Red.
///   `init(title: String, icon: Image? = nil, variant: Variant = .standard, isLoading: Bool = false, action: @escaping () -> Void)`
///   `// PrimaryGlassButton(title: "Начать перевод", action: start)`
///
/// - **`InlineButton`** — small Settings-row button; `.base` uses
///   `.buttonStyle(.glass)`, `.primary` uses `.buttonStyle(.glassProminent)`.
///   `init(_ title: String, icon: Image? = nil, variant: Variant = .base, isLoading: Bool = false, action: @escaping () -> Void)`
///   `// InlineButton("Переустановить", icon: Image(systemName: "arrow.clockwise"), action: reinstall)`
///
/// - **`MutedLink`** — muted-white external link button with ↗ glyph.
///   `init(_ title: String, action: @escaping () -> Void)`
///   `// MutedLink("Получить ключ") { open(url) }`
///
/// ### Inputs & toggles
///
/// - **`SegmentedToggle`** — neutral Call/Listen segmented control.
///   `init(selection: Binding<SessionMode>, segments: [Segment])`
///   `// SegmentedToggle(selection: $mode)`
///
/// - **Native `Toggle`** with `.toggleStyle(.switch)` — on/off switches
///   in Settings. macOS 26 supplies Liquid Glass styling automatically;
///   we deleted the custom `PillToggle` in favour of the system control.
///   `// Toggle("", isOn: $autostart).labelsHidden().toggleStyle(.switch)`
///
/// - **`NeutralSlider`** — thin wrapper around native `Slider` with a
///   white tint (no system accent blue). The two pure helpers
///   `fraction(of:in:)` and `fillOpacity(for:)` remain on the type
///   for downstream callers and unit tests.
///   `init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, leadingLabel: String? = nil, trailingLabel: String? = nil)`
///   `// NeutralSlider(value: $volume, in: 0...1)`
///
/// - **`SecretInput`** — password field with `Показать` / `Скрыть` text toggle.
///   `init(text: Binding<String>, placeholder: String = "")`
///   `// SecretInput(text: $apiKey, placeholder: "sk-proj-…")`
///
/// - **`SearchField`** — ghost-underline search input used in dropdown headers.
///   `init(text: Binding<String>, placeholder: String = "Найти…", autoFocus: Bool = true)`
///   `// SearchField(text: $query)`
///
/// - **`HotkeyRecorder`** — clickable mono label that records a key combo.
///   `init(hotkey: Binding<Hotkey?>, isRecording: Binding<Bool>, onStartRecording: @escaping () -> Void)`
///   `// HotkeyRecorder(hotkey: $hk, isRecording: $rec, onStartRecording: start)`
///
/// ### Layout & structure
///
/// - **`SectionHeader`** — uppercase caps section title (mono, 10pt).
///   `init(_ text: String)`
///   `// SectionHeader("Аудио")`
///
/// - **`SettingsRow`** — label/icon row with trailing control + optional hint.
///   `init(_ title: String, icon: Image? = nil, hint: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing)`
///   `// SettingsRow("Микрофон", icon: Image(systemName: "mic")) { dropdownTrigger() }`
///
/// - **`StepCard`** — onboarding step with icon plaque, status badge, body slot.
///   `init(title: String, icon: Image, status: StepCardStatus, @ViewBuilder content: @escaping () -> Content)`
///   `// StepCard(title: "BlackHole", icon: Image(systemName: "speaker.wave.2.fill"), status: .pending) { … }`
///
/// - **`DashedDivider`** — half-point dashed horizontal rule.
///   `init(color: Color = UnisonColors.whiteAlpha(0.08), dash: [CGFloat] = [3, 3])`
///   `// DashedDivider()`
///
/// ### Pickers & dropdowns
///
/// - **`LanguageBar`** + **`LanguageSideButton`** — "Я говорю / Слушаю" popover bar.
///   `init(pair: LanguagePair, openSide: Side?, isWarning: Bool, onOpenDropdown: @escaping (Side) -> Void)`
///   `// LanguageBar(pair: pair, openSide: openSide, isWarning: false) { side in toggle(side) }`
///
/// - **`LanguagePickerDropdown`** — portal-style language picker with search + keyboard nav.
///   `init(languages: [Language] = Language.allCases, selection: Binding<Language>, onPick: @escaping (Language) -> Void, onCancel: @escaping () -> Void = {})`
///   `// LanguagePickerDropdown(selection: $lang, onPick: pick)`
///
/// - **`FlagText`** — fixed-size flag emoji that ignores parent foreground tint.
///   `init(_ flag: String, size: CGFloat = 14)`
///   `// FlagText(language.flagEmoji)`
///
/// ### Transcript surfaces
///
/// - **`Bubble`** + **`TypingDots`** — single transcript bubble with corner tail.
///   `init(speaker: Speaker, primary: String, secondary: String, isContinued: Bool, isLastInGroup: Bool, isLive: Bool, scale: Double = 1.0)`
///   `// Bubble(speaker: .me, primary: "...", secondary: "...", isContinued: false, isLastInGroup: true, isLive: false)`
///
/// - **`BubbleGroupView`** — stack of `BubbleGroup`s with design-spec gaps.
///   `init(groups: [BubbleGroup], scale: Double = 1.0)`
///   `// BubbleGroupView(groups: vm.bubbleGroups, scale: vm.bubbleScale)`
///
/// - **`ControlPill`** — transcript-window pill (dot + timer + gear + hide + stop).
///   `init(isActive: Bool, elapsedLabel: String, isHidden: Bool, isSettingsOpen: Bool, onToggleSettings: @escaping () -> Void, onToggleHidden: @escaping () -> Void, onStop: @escaping () -> Void)`
///   `// ControlPill(isActive: true, elapsedLabel: "00:42", isHidden: false, isSettingsOpen: false, onToggleSettings: …, onToggleHidden: …, onStop: …)`
///
/// - **`TranscriptSettingsPopover`** — glass popover above the pill (size + volume).
///   `init(sizeIndex: Binding<Double>, volume: Binding<Double>)`
///   `// TranscriptSettingsPopover(sizeIndex: $size, volume: $vol)`
///
/// ## Authoring rules
///
/// - Use the design tokens above instead of magic numbers.
/// - For panels with the canonical glass material, use `.liquidGlass(cornerRadius:)`.
///   Use 22–26 for main panels, 12–14 for inner blocks.
/// - Aurora gradients live in `auroraBackground()` — do not re-implement.
/// - The kit must never import `AppKit`; host integrations belong in `UnisonApp`.
public enum UnisonUIKit {}
