I now have enough context to produce the implementation plan. Let me write it out.

# UI Integration Plan: Aurora Liquid Glass Migration

The following is the complete plan. Save it to `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/docs/superpowers/plans/2026-05-20-ui-integration.md` (I cannot create files in read-only mode).

---

# Unison UI Integration — Aurora Liquid Glass Migration

**Date:** 2026-05-20
**Status:** Plan for execution. Read-only design output; no code changes performed.
**Inputs:** `docs/design/DESIGN.md`, `design/{logo,menubar,popover,onboarding,transcript,settings}-final/index.html`
**Goal:** Replace the four placeholder SwiftUI views with production implementations matching the finalized HTML designs while preserving all 93 existing tests, observation patterns, and module boundaries.

---

## 0. Constraints & Conventions Recap

- **swift-tools-version 6.0**, `platforms: [.macOS(.v14)]` — minimum macOS 14.0. **Do not** raise the platform requirement.
- **Modules:** `UnisonDomain` (pure value/protocols), `UnisonTranslation`, `UnisonAudio`, `UnisonSystem`, `UnisonUI` (SwiftUI + Observation), `UnisonApp` (executable with AppKit interop). `UnisonUI` **only** imports `Foundation`/`Observation`/`SwiftUI`/`UnisonDomain`. AppKit lives strictly in `UnisonApp` (StatusItem, NSPanel, NSWindow controllers).
- **Observation:** ViewModels are `@MainActor @Observable final class` exposing mutable `var` state. Views consume them via `@Bindable`. Keep this pattern.
- **Naming:** `*View`, `*ViewModel`, `*WindowController`. Test files mirror with `*Tests.swift` using **Swift Testing** (`import Testing`, `@Test`).
- **Existing tests reference `PopoverViewModel`, `OnboardingViewModel`, `SettingsViewModel`** from `UnisonUI` (test target `UnisonDomainTests` already depends on both `UnisonDomain` and `UnisonUI`). Public init signatures and method names of these VMs must remain backward-compatible — any new state should be additive.
- **Russian copy** is canonical (Info.plist mic description, design copy). All UI strings remain in Russian, matching `DESIGN.md` §7.
- **App is a status-item-only app:** `LSUIElement=true` is already set in `Resources/Info.plist`. No Dock icon, no main menu visible. We must not introduce `WindowGroup` from `App` body; `UnisonAppEntry` declares `Settings { EmptyView() }` purely as scaffolding so `App` is satisfied.

---

## 1. Risks & Unknowns (resolve first, before Phase 2)

The HTML designs use CSS features that have **no direct SwiftUI equivalent**. Fallbacks must be agreed before any visual work begins.

### 1.1 SVG `feDisplacementMap` "Liquid Glass" refraction
- **No SwiftUI/AppKit primitive** maps to this filter. Trying to render via a custom `CALayer` + `CIFilter` chain is too expensive on a constantly-redrawing window.
- **Decision:** approximate the material with `NSVisualEffectView` (`material = .hudWindow` or `.popover`, `blendingMode = .behindWindow`) wrapped via `NSViewRepresentable`, plus an overlay `LinearGradient` (the "specular highlight" from §1.3) and a conic-gradient stroke for the rim. The displacement refraction is dropped — this is acceptable per `DESIGN.md` §10.3 which already flags Safari as a graceful fallback. Capture this trade-off in the file header of `LiquidGlassPanel.swift`.
- Reusable wrapper name: `LiquidGlassPanel` with form-classes via modifier (`.glassRaised(...)`, `.glassDropdown(...)`).

### 1.2 Aurora background gradient
- Use a vanilla SwiftUI `ZStack` of `RadialGradient`s (3 ellipses) on top of a `LinearGradient` (`#0a0820 → #100c2e → #1a1142`). Coordinates exactly from `DESIGN.md` §1.1. Extract into `AuroraBackground` view (extension on `View` as `.auroraBackground()`).

### 1.3 Logo rendering
- HTML uses `<symbol id="logo-unison">` (256×256, stroke). We need it in three contexts: menubar template image (18×18 monochrome), onboarding header (32×32 white), about box (44×44 white on Aurora plate).
- **Decision:** ship the logo as a SwiftUI `Shape` (`UnisonLogoShape`) implementing the U + four bars by stroking `Path` segments matching the SVG `d=` coordinates. This avoids bundling assets, scales perfectly, and the `paused` variant is just a flag that skips the side bars. For the menubar status item we additionally bake an `NSImage` (template image) at 22×22 — see Phase 4.
- Rationale: no resource pipeline changes, deterministic rendering, easier to animate `pulse` (opacity + scale via `.animation`).

### 1.4 Portal-style dropdowns (lang picker / settings dropdowns)
- HTML uses absolute-positioned siblings inside the popover-wrap to escape stacking contexts. SwiftUI on macOS 14 supports overlays via `.popover(isPresented:)` and `.menu`, but the visual styling won't match the glass aesthetic.
- **Decision (popover lang picker):** render the dropdown as a child `ZStack` element inside the same popover content using `.overlay(alignment: .topLeading)` with absolute offset computed from anchor frame via `GeometryReader` + `PreferenceKey`. Because the popover hosts both anchor and dropdown inside one `NSHostingView`, no separate NSWindow needed.
- **Decision (settings window dropdowns):** because dropdowns must escape the scroll container and overflow the window edge, present them as a child `NSPopover` (transient behavior) anchored to the trigger button. The hosting controller is set up in `UnisonApp/SettingsWindowController.swift` (new). The dropdown SwiftUI content is shared with the popover via `LanguagePickerDropdown` view. The trigger and the dropdown view both live in `UnisonUI`, only the `NSPopover` host is in `UnisonApp`.
- For onboarding: no dropdowns needed.

### 1.5 Global hotkeys (`⌃⌥U`, `⌃⌥T` from Settings)
- macOS API: `NSEvent.addGlobalMonitorForEvents` (system-wide, requires Accessibility permission for some key combos) or `Carbon.HIToolbox.RegisterEventHotKey` (precise, no accessibility prompt for keys with modifiers).
- **Decision:** thin Swift wrapper around `RegisterEventHotKey` in `UnisonApp/HotkeyService.swift` (new). API: `register(id: HotkeyID, keyCode: UInt32, modifiers: UInt32, handler: @MainActor () -> Void) throws`. The wrapper exposes only Cocoa-level types; the parsing of `⌃⌥U` strings to key codes lives in `UnisonUI/HotkeyParser.swift` (testable, no AppKit). VMs hold the formatted string + a `Hotkey` value struct (modifiers bitmask + `keyCode`); the wiring layer translates and registers.
- **Risk to flag in code header:** `Carbon.HIToolbox` is deprecated for some symbols on macOS 26 but still functional. Defer migration to `NSEvent.addLocalMonitorForEvents` only when global support is dropped. The plan does not require an `accessibility` prompt — `RegisterEventHotKey` works without it.

### 1.6 Menubar template behavior
- Status item icons must be set as **template images** so AppKit tints them per state (active/highlighted/dark mode). Cyan "active" pulse and coral "error" must be rendered as non-template images (otherwise they'd be tinted black/white).
- **Decision:** render four pre-baked `NSImage` variants (idle template, paused template, active color, error color with badge). For active state, also animate using a `Timer` driving alpha. Implementation in `StatusItemController.swift`. Image generation via a tiny renderer that draws `UnisonLogoShape` paths into an off-screen `CGContext` (utility in `UnisonApp/MenubarIcons.swift`).

### 1.7 macOS 26 Liquid Glass APIs
- macOS 26 ships `ContainerRelativeShape`, `glassBackgroundEffect`, etc. We target macOS 14 minimum, so these are off-limits unconditionally for now. Gate any future use behind `if #available(macOS 26, *)`. **Do not introduce** in this migration.

### 1.8 Speaker disambiguation for "me" bubble
- The transcript design treats `speaker == .me` as `align-self: flex-start` (left), `peer` as `flex-end` (right). Existing `TranscriptStore.apply()` only handles language target lookup but not "primary vs secondary" routing. The view layer (`BubbleView`) must derive:
  - `me` bubble primary = `originalText`; secondary = `translatedText`
  - `peer` bubble primary = `translatedText`; secondary = `originalText`
- This logic does **not** require domain changes; it's a presentation concern. Helper on `TranscriptViewModel` or a free function in `UnisonUI/TranscriptFormatting.swift`.

### 1.9 Bubble grouping & split (240-char threshold)
- HTML script groups continuous bubbles from the same speaker, splits long primaries at sentence boundaries. Existing `TranscriptStore` doesn't model groups — it stores raw `TranscriptEntry` per id with mutating string append.
- **Decision:** add a presentation-layer `TranscriptGrouper` (in `UnisonUI/TranscriptGrouping.swift`) that takes `[TranscriptEntry]` + `LanguagePair` and returns `[BubbleGroup]` where each group is `(speaker, [BubbleViewModel])` and each `BubbleViewModel` is one `<= 240` char chunk with `isLastInGroup`, `isFirstInGroup`, `isLive` flags. Pure function, easy to unit-test. **No domain changes.**

### 1.10 Info.plist additions
- `LSUIElement` already present.
- `NSMicrophoneUsageDescription` already present.
- No new keys required for hotkey functionality (Carbon API).
- No bundle resources to add — fonts come from the system (we'll use SF Pro / system fonts as a fallback because Google Fonts are not allowed at runtime; see §2.1 for font strategy).

### 1.11 Fonts
- DM Sans and IBM Plex Mono are **not** macOS system fonts and we don't want to ship a fonts pipeline now (CTFontManagerRegisterFontsForURL adds bundling complexity).
- **Decision for v1:** use system equivalents — `.system(.body, design: .default, weight: .medium)` for DM Sans, `.system(.body, design: .monospaced)` for IBM Plex Mono. Track in a single `FontTokens` enum so swapping to bundled fonts later is a one-file change. Document this trade-off in `Sources/UnisonUI/Design/Fonts.swift`.

---

## 2. Phased Implementation

Files paths below are absolute; the worktree root is `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/`.

### Phase 1 — Foundation: Design Tokens & Logo

**Goal:** establish single-source-of-truth for color, font, spacing, animation, plus the universal logo shape.

#### Step 1.1 — Create `UnisonUI/Design/` directory and design tokens

Files to create (all under `Sources/UnisonUI/Design/`):

| File | Purpose | Key API |
|---|---|---|
| `Colors.swift` | `enum DesignColor` with static `Color` properties matching `DESIGN.md §3` | `ready`, `active`, `warn`, `stop`/`error`, `pageBg`, `textPrimary`, `textMuted`, `textFaded`, and white-with-opacity helpers `whiteAlpha(_:)` |
| `Fonts.swift` | `enum FontTokens` mapping role → `Font` | `windowTitle`, `body`, `bodySemibold`, `monoCaption`, `sectionHead`, `langValue`, `miniLabelCaps`, `monoLabel`, etc. Document substitution policy in header. |
| `Spacing.swift` | 4-base scale constants and `enum Radii` | `r4...r64`, `Radii.popoverPanel = 24`, `Radii.dropdown = 13`, `Radii.button = 13`, `Radii.smallButton = 8`, `Radii.pill = 999` |
| `AnimationTokens.swift` | Standard durations / easing curves | `.hover = .easeOut(duration: 0.15)`, `.press = .easeInOut(duration: 0.08)`, `.dropdown = .easeOut(duration: 0.16)`, `.state = .easeOut(duration: 0.2)`, plus `.pulseLogo` (1.6s repeat) |

No tests required for tokens (compile-time only). Tests for any computed helper added inline.

#### Step 1.2 — `UnisonLogoShape`

File: `Sources/UnisonUI/Design/UnisonLogoShape.swift`

- `struct UnisonLogoShape: Shape` with `var showsVoiceStreams: Bool = true`.
- `func path(in rect: CGRect) -> Path` — normalize coordinates from 256×256 viewBox, draw:
  - U body: `M82,66 V146 C82,177.5 102.5,198 128,198 C153.5,198 174,177.5 174,146 V66`
  - Left bars: `M58,86 V136` and `M38,102 V126`
  - Right bars: `M198,86 V136` and `M218,102 V126`
- Round caps + joins via `Path` then `stroke(lineWidth:)`.
- Companion `View`: `UnisonLogoView(showsVoiceStreams: Bool = true, lineWidth: CGFloat = 12)` that returns the shape stroked in `currentColor` (i.e. `.foregroundStyle(.tint)` driven by parent).
- Test (`Tests/UnisonDomainTests/UnisonLogoShapeTests.swift` — UI tests can still live in this target since it depends on UnisonUI): assert `path(in: 256×256)` contains expected subpaths via `CGPath.applyWithBlock` element walk. One smoke test confirms shape compiles and produces non-empty path.

**Dependencies:** none. Start here.

#### Step 1.3 — Liquid Glass primitives

File: `Sources/UnisonUI/Design/LiquidGlassPanel.swift`

- `struct LiquidGlassBackground: View` — `NSViewRepresentable` wrapping `NSVisualEffectView(material: .popover, blendingMode: .behindWindow, state: .active)`. **Wait — this breaks the UI/UnisonUI boundary because `NSVisualEffectView` is AppKit.** Two options:
  - (a) Move this into a separate file `Sources/UnisonUI/Design/PlatformGlass.swift` since AppKit is *available* on macOS targets; `UnisonUI` already builds for macOS only. SwiftUI on macOS already exposes `Material` (`.regularMaterial`, `.thickMaterial`) which uses `NSVisualEffectView` under the hood. So **prefer SwiftUI's native `Material`** — no AppKit import needed.
  - (b) Keep it AppKit-free by using `.background(.regularMaterial)` (macOS 14 supports). Verify visual outcome is acceptable; tune with custom dark vibrancy via `.environment(\.colorScheme, .dark)` on the host.
- **Decision:** use `.background(.thickMaterial)` for `.glass-raised` (dropdown bg), `.background(.regularMaterial)` for panels. Add overlay layers manually:
  - Linear gradient `[rgba(255,255,255,0.08), rgba(255,255,255,0.02)]` top-to-bottom
  - Specular highlight: `RadialGradient` clipped to top 60%
  - Conic rim: `AngularGradient` masked to `1pt` inset border via `.strokeBorder`

- API:
  ```
  extension View {
    func liquidGlassPanel(cornerRadius: CGFloat = 24) -> some View
    func liquidGlassRaised(cornerRadius: CGFloat = 13) -> some View   // dropdowns
  }
  ```
- Internal `LiquidGlassDecoration` view encapsulates the specular + conic rim + inset shadow.

- A short header comment notes: "SVG `feDisplacementMap` refraction is intentionally omitted — no SwiftUI/AppKit equivalent at acceptable cost. Material + gradient overlays approximate `.glass` per DESIGN.md §10.3 (graceful fallback)."

Dependencies: Colors, Radii.

#### Step 1.4 — Aurora background

File: `Sources/UnisonUI/Design/AuroraBackground.swift`

- `struct AuroraBackground: View` rendering `ZStack`:
  - `LinearGradient(colors: [.init(hex: 0x0a0820), .init(hex: 0x100c2e), .init(hex: 0x1a1142)], startPoint: .top, endPoint: .bottom)`
  - 3 `RadialGradient` overlays (cyan, magenta, lavender) per `DESIGN.md §1.1` with `.blendMode(.normal)` and individual alignment offsets via `GeometryReader` (proportional placement at 80%/30%, 25%/70%, 60%/90%).
- `extension View { func auroraBackground() -> some View }` modifier.
- Used by Onboarding, Settings, Transcript (transcript zone area).

Dependencies: Colors.

**Phase 1 deliverable check:** project still compiles, no existing tests break (these are all new files; nothing imported yet). Run `scripts/test.sh`.

---

### Phase 2 — Reusable Components

All components live under `Sources/UnisonUI/Components/`. Each is a single-file `View` with a `#Preview` block (SwiftUI Previews) and a public API that downstream views consume.

#### 2.1 `StatusDot.swift`
- `struct StatusDot: View` taking `enum Status { case ready, active, warn, error }` and `size: CGFloat = 7`.
- `.active` adds `dotPulse` animation (1.6s repeating opacity 1↔0.5).
- Glow via `.shadow(color:radius:)` matching color.
- Use SwiftUI `withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: true))`.

#### 2.2 `IconButton.swift`
- `struct IconButton<Icon: View>: View` for 28×28 gear / settings / close buttons.
- Press scale 0.94, hover bg, transparent default.
- Initializer takes `action: () -> Void` + `@ViewBuilder icon`.

#### 2.3 `PrimaryGlassButton.swift`
- Big Start/Stop style (`.start-btn`) — full-width, gradient bg, inset shadow, press scale 0.98.
- Variants: `.standard`, `.destructive` (red gradient for Stop). State: `.disabled` flag handled via SwiftUI `.disabled()`.
- Loading state: when `isLoading: Bool` → swap label, show spinner (CSS `spin`). Use `.rotationEffect` with `.repeatForever`.

#### 2.4 `SegmentedToggle.swift`
- Two-segment Call/Listen control (`.mode-toggle`).
- Generic over `Selection: Hashable`: `init(selection: Binding<Selection>, segments: [Segment])` where `Segment` carries label, icon, value.
- Hand-drawn — does not use `Picker(.segmented)` (that's macOS native blue, conflicts with neutral palette).
- "on" segment uses raised glass treatment with inset shadow.

#### 2.5 `Toggle.swift` (the pill switch)
- `struct PillToggle: View` to avoid clash with SwiftUI's `Toggle`.
- 34×19 base, 14×14 thumb, animates `left` offset, `on` state uses `DesignColor.ready` background.
- Public init: `(isOn: Binding<Bool>)`.

#### 2.6 `NeutralSlider.swift`
- T2 vertical-handle slider with neutral palette (DESIGN.md §5.13).
- Custom drawn: track is `Capsule` 6pt tall; fill clipped via `.mask` with width tied to value. Thumb is 4×18 rectangle (`Capsule`) absolutely positioned, drag gesture.
- Fill opacity interpolates `0.12 → 0.85` based on value fraction.
- Init: `(value: Binding<Double>, in: ClosedRange<Double>, step: Double? = nil)` + optional `sideLabels: (leading: String?, trailing: String?)`.
- Tests: `Tests/UnisonDomainTests/NeutralSliderTests.swift` — pure helper `func sliderFillOpacity(for fraction: Double) -> Double` returns 0.12+0.73*fraction clamped to [0,1]. Verify boundary cases.

#### 2.7 `SecretInput.swift`
- Bordered HStack: `SecureField` ↔ `TextField` swap by `isVisible` state. Trailing `Button("Показать" / "Скрыть")` with text styling (not eye icon — per DESIGN §5.16).
- Monospaced font; rounded 7pt; subtle bg.
- Init: `(text: Binding<String>, placeholder: String)`.

#### 2.8 `HotkeyRecorder.swift`
- Button-like view that shows the current hotkey or "нажмите…" while recording.
- Uses NSEvent local monitor when recording starts (added via `.onAppear` of the wrapper view? — actually best done in UnisonApp because we need global state).
- **Decision:** view in `UnisonUI` exposes:
  ```
  struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey?
    let onCapture: (Hotkey) -> Void
  }
  ```
  where `Hotkey` is a value type in `UnisonUI/Hotkey.swift`. The actual key event capture uses SwiftUI `.onKeyPress(phases: .down)` (macOS 14+) — yes, this is available. Verify with a small `#Preview` test before committing. If not, fall back to AppKit local monitor wrapped in `NSViewRepresentable` (still allowed because SwiftUI on macOS already uses AppKit internally).
- Pulse animation on `.recording`.
- Filter: ignore key events without modifiers (only one modifier among `cmd/ctrl/opt/shift`); Esc cancels.
- Unicode mapping helper: `func formatHotkey(_ event: NSEvent) -> String?` returns `⌃⌥U` style string. Pure-Swift, testable in `HotkeyParserTests.swift`.

#### 2.9 `SaveIndicator.swift`
- `struct SaveIndicator: View` taking `@State`-driven `isShown: Bool` from parent, plus `Animation` triggers.
- Simple HStack: `Image(systemName: "checkmark")` (color `.ready`) + `Text("сохранено")` (mono caption).
- 0.25s fade-in, hold 1.6s, fade-out — managed by parent via `.task(id: change)` or a dedicated `SaveIndicatorController` `@Observable` helper.

#### 2.10 `WarnRow.swift`
- Inline amber warning row used in popover ("Выбран одинаковый язык").
- `init(message: String, icon: Image = warningTriangle)`.

#### 2.11 `ErrorRow.swift`
- Coral error row for onboarding cards. `init(title: String, detail: String, action: ErrorAction?)`.
- `enum ErrorAction { case retry(() -> Void), openSettings(() -> Void), inline }` — covers `Повторить`, `Открыть Настройки ↗`, and inline-only (key validation).

#### 2.12 `SectionHeader.swift`
- The IBM Plex Mono caps mini-header used in Settings.
- Init: `init(_ text: String)`.

#### 2.13 `LanguagePickerDropdown.swift` (shared by popover + settings)
- The portal dropdown content: search row (ghost underline `S1`) + scrollable list of `Language` rows.
- `init(languages: [Language], selected: Language, onPick: (Language) -> Void)`.
- Internal `@State var query: String`, `@State var keyboardFocus: Int`, supports ↑↓ Enter Esc.
- Selected row: `font.weight(.semibold)`, white text, check icon on the right.
- Hover/keyboard-focused row: white 10% bg.
- Empty state: "Ничего не найдено".
- Tests (`Tests/UnisonDomainTests/LanguagePickerFilterTests.swift`): pure filter helper `func filterLanguages(_ langs: [Language], query: String) -> [Language]` — matches by `displayName` substring (case-insensitive) **and** by `rawValue` substring (`"en"` matches English by code, `"中"` matches Chinese). Cover empty query, no results, mixed case.

#### 2.14 `LanguageBar.swift` (popover-specific composite)
- Composite "Я говорю / Слушаю" bar with left/right `LangSide` taps that open dropdowns and a center `arrow-a` SVG (custom `Shape`).
- Init: `(pair: Binding<LanguagePair>, openSide: Binding<Side?>, isWarning: Bool)`.
- `enum Side { case mine, peer }` lives here.
- Renders the dropdown using `.overlay` aligned to whichever side is open; uses `GeometryReader` + `PreferenceKey` to anchor.

#### 2.15 `FlagText.swift`
- Tiny helper view: language flag emoji + display name.
- The flag mapping moves out of `PopoverViewModel.flag(_:)` into `Language+Flag.swift` (extension in `UnisonUI`, since the domain enum has no flag knowledge today).
- **Important — boundary check:** the flag extension goes into `Sources/UnisonUI/Extensions/Language+Flag.swift` so it stays presentation. Update `PopoverViewModel.languagePairDisplay` to call this extension instead of the private method. This is the only refactor of an existing VM in Phase 2.

#### 2.16 `Bubble.swift` + `BubbleGroupView.swift`
Transcript bubbles per DESIGN §5.14.
- `struct Bubble: View` with props `text: String, secondaryText: String, side: Side, isContinued: Bool, isLastInGroup: Bool, isLive: Bool, scale: Double`.
- All radii/padding scale linearly with `scale` (driven by transcript size slider).
- `.me` left-aligned with tail bottom-left, cyan-tinted bg. `.peer` right-aligned, neutral bg.
- `.continued` softens top corner; `.no-tail` (set on non-last in group) brings tail corner back to full radius.
- `isLive` adds typing dots view at end of primary text using SwiftUI `HStack` of three Circles with staggered `repeatForever` animation.
- Entry animation: `.transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.93)).animation(.spring(...)), removal: .opacity.animation(.easeOut(duration: 0.7))))`.
- `BubbleGroupView` collects ordered `[BubbleViewModel]` and renders with appropriate gap (14pt × scale between groups, 3pt × scale inside a group).

#### 2.17 `LanguageDropdown` portal hosting (`UnisonApp` side)
Companion file in `Sources/UnisonApp/Glue/DropdownPopover.swift`:
- Small helper to host any `SwiftUI` view in an `NSPopover` with `.applicationDefined` behavior, used by Settings dropdowns. Not used by popover-final lang picker (that one is in-popover).

**Phase 2 deliverable check:** `swift build` cleanly; `scripts/test.sh` passes (93 tests + new pure helper tests for filter, slider opacity, hotkey parser). All components have at least one `#Preview` for manual visual verification.

---

### Phase 3 — Screens

#### 3.1 — Popover (`Sources/UnisonUI/Views/PopoverView.swift` — replace)

**Required additions to `PopoverViewModel`** (additive, backwards-compatible):
- `var elapsedSecondsString: String` — formats `running` time as `mm:ss` (computed property; pulled from existing `runningTimeSeconds`).
- `var statusKind: StatusDot.Status` — derived from `state` + validation: `.warn` when languages equal, `.active` while translating, `.ready` otherwise, `.error` on `.error` state.
- `var primaryButtonTitle: String` — `"Остановить"` while active, `"Начать перевод"` when ready.
- `var primaryButtonIcon: ButtonIcon` — `.stop` or `.play`.
- `var isLanguagePairValid: Bool` — `pair.mine != pair.peer`.
- `var canStartStrict: Bool` — `canStart && isLanguagePairValid`.
- `func toggleSessionMode()` — convenience.
- `func updateLanguagePair(_ pair: LanguagePair)` — currently mutating `settings.languagePair` is done at the call site; centralize so the view doesn't write to settings directly. Notify the wider app of changes via existing AppDelegate observation pattern. (If we need a callback, mirror `SettingsViewModel.onChange` — but simpler is: AppDelegate observes the orchestrator's `state` already; the popover writes to `settings` and `Composition` already pipes via shared instances.)
- Add a `Timer` driver: not in the VM (timers in tests are flaky). Instead, the View uses `TimelineView(.periodic(from: .now, by: 1.0))` to drive the timer label off `state`'s start date. No ViewModel changes needed for the ticker.

**View structure:**
```
VStack(spacing: 12) {
  TopRow: StatusDot + "Unison" brand + Spacer + Gear icon button → opens Settings window
  SegmentedToggle (Call/Listen) bound to settings.sessionMode
  LanguageBar (bound to settings.languagePair, openSide state)
  if !isLanguagePairValid: WarnRow("Выбран одинаковый язык")
  PrimaryGlassButton(title, icon, destructive: state.isActive, action: toggle)
  if state.isActive: Text(elapsedSeconds, mono caption, center)
}
.padding(16)
.frame(width: 340)
.background(LiquidGlassPanel(radius: 24))
```

Width is exactly **340** (DESIGN §4.3).

Gear button action calls a new closure on the view: `onOpenSettings: () -> Void`. Inject from `StatusItemController` so opening settings is decoupled. (Existing view doesn't have this — that's why settings was never reachable.)

**Tests** (`Tests/UnisonDomainTests/PopoverViewModelTests.swift` — extend existing):
- `elapsedSecondsString` from a `Date` 2.5s ago → `"00:02"`.
- `statusKind` matrix: idle/ready/warn(same lang)/active/error → maps correctly.
- `isLanguagePairValid` matrix.

#### 3.2 — Onboarding (`Sources/UnisonUI/Views/OnboardingView.swift` — replace)

**ViewModel additions** to `OnboardingViewModel`:
- `enum StepStatus { case pending, inProgress, done, error(String) }` and `var status: [OnboardingStepKind: StepStatus]` so the view shows per-card error rows.
- `var apiKeyDraft: String` (mutable; UI binds directly) + `func validateAPIKey(_:) -> Bool` returning `key.hasPrefix("sk-") && key.count >= 20` (matches HTML script).
- Mutate `status[.blackHole]` to `.inProgress` before calling `installer.runBundledInstaller()`; on throw set `.error("Не удалось установить — скорее всего, не введён пароль администратора.")`.
- Same for mic.
- `var canFinish: Bool { steps.allSatisfy(\.isDone) }`.

**View structure:**
```
VStack(spacing: 20) {
  Header: title "Установка" (DM Sans 300, 26pt, -0.03em) + close button (closes window — call onDismiss closure)
  VStack(spacing: 10) {
    StepCard(kind: .blackHole, ...)
    StepCard(kind: .microphone, ...)
    StepCard(kind: .apiKey, ...) — special inline secret input + Save button
  }
  Footer: HStack { Text("X / 3 готово") (mono) Spacer PrimaryGlassButton("Готово", disabled: !canFinish) }
}
.padding(24)
.frame(width: 480)
.background(LiquidGlassPanel(radius: 22))
.auroraBackground()    // applied to window background, not panel
```

**`StepCard.swift`** (component, lives in `UnisonUI/Components/`):
- Card-style row with leading 36×36 icon plaque (uses `Image(systemName:)` for now — `speaker.wave.2`, `mic`, `key`), title, trailing `done` check icon (when done), `card-action` bottom area with hint + primary button.
- States: `idle` (icon white-muted, bordered), `done` (green tint), `error` (coral tint + nested `ErrorRow`).
- For the API-key card the action area is a custom layout: `SecretInput` + Save button + small "Получить ключ ↗" link below.
- Init takes `OnboardingStepViewModel` (simple value struct) + handlers.

`actionButton` matches per step:
- `.blackHole`: "Установить" → `await vm.installBlackHole()`. While running: spinner + "Установка..." + disabled.
- `.microphone`: "Разрешить" → `await vm.requestMicPermission()`.
- `.apiKey`: SecretInput bound to `apiKeyDraft`, Save button calls `vm.saveAPIKey(apiKeyDraft)`. On validation failure (`!validateAPIKey`) set `.error(...)`.

Error actions in `ErrorRow`:
- `.blackHole`: retry — re-trigger `installBlackHole()`.
- `.microphone`: open System Settings — calls `permissions.openSystemSettings(.microphone)` (existing API).
- `.apiKey`: inline-only, clears on next edit.

**Tests** (`Tests/UnisonDomainTests/OnboardingViewModelTests.swift` — extend):
- `validateAPIKey("abc")` → false; `validateAPIKey("sk-proj-1234567890ab")` → true.
- `status` transitions on success/failure (using mock installer & permissions).

#### 3.3 — Settings (`Sources/UnisonUI/Views/SettingsView.swift` — replace)

This is the most complex screen. Per DESIGN §12.2: 560pt wide, max-height 540 with scroll, sections via `SectionHeader`, auto-save (`SaveIndicator` in title bar).

**ViewModel additions** to `SettingsViewModel`:
- Already has language pair, devices, mix volume. Add:
  - `var apiKey: String` (read/write via `KeychainService`). Inject `keychain` into init.
  - `var hotkeyStartStop: Hotkey?` and `var hotkeyShowTranscript: Hotkey?` persisted via UserDefaults.
  - `var autostart: Bool`, `var hideMenuOnSession: Bool` (UserDefaults).
  - `var blackHole2chInstalled: Bool { deviceRegistry.findBlackHole2ch() != nil }`, same for 16ch.
  - `var blackHoleReinstallStatus: ReinstallStatus = .idle` (`case idle, inProgress, success, failure(String)`).
  - `func reinstallBlackHole() async throws` — calls `installer.runBundledInstaller()`. Inject `installer`.
- Update `Composition.swift` to inject these dependencies into `SettingsViewModel`.

**View layout:**
```
VStack(spacing: 0) {
  TitleBar (custom traffic lights mock not needed — use NSWindow's native title; insert SaveIndicator into NSWindow's titlebar via NSToolbar item or use a custom `.windowToolbar`. Simpler v1: show save indicator inside the content area's top.)
  ScrollView {
    SectionHeader("АУДИО")
    SettingsRow(label: "Микрофон", icon: mic) { DeviceDropdown(devices: availableInputs, selected: settings.inputDeviceUID) }
    SettingsRow(label: "Динамик", icon: speaker) { DeviceDropdown(devices: availableOutputs, selected: settings.outputDeviceUID) }
    SettingsRow(label: "Громкость оригинала", hint: "Тихий фон под переводом во время звонка") { NeutralSlider(value: $originalMixVolume, in: 0...1) + "X%" label }

    SectionHeader("ЯЗЫКИ ПО УМОЛЧАНИЮ")
    SettingsRow(label: "Я говорю") { LangDropdownTrigger }
    SettingsRow(label: "Слушаю") { LangDropdownTrigger }

    SectionHeader("OPENAI")
    SettingsRow(label: "API ключ", icon: key, hint: "Хранится в Keychain. Получить ключ ↗") { SecretInput(text: $apiKey, placeholder: "sk-proj-...") }

    SectionHeader("HOTKEYS")
    SettingsRow(label: "Старт / стоп", icon: kbd) { HotkeyRecorder(...) }
    SettingsRow(label: "Показать транскрипт", icon: kbd) { HotkeyRecorder(...) }

    SectionHeader("BLACKHOLE")
    SettingsRow(label: "BlackHole 2ch") { StatusDot(...) + Text("установлен"/"не установлен") }
    SettingsRow(label: "BlackHole 16ch") { ... }
    SettingsRow(label: "Виртуальные аудио-устройства", hint: "Нужны для перехвата...") { InlineButton("Переустановить", icon: refresh, action: reinstall, isLoading: status == .inProgress) }

    SectionHeader("ПОВЕДЕНИЕ")
    SettingsRow(label: "Запускать при логине") { PillToggle(isOn: $autostart) }
    SettingsRow(label: "Скрывать меню при старте сессии") { PillToggle(isOn: $hideMenuOnSession) }

    SectionHeader("О ПРИЛОЖЕНИИ")
    SettingsRow(label: "Версия") { Text("1.0.0 · build 42") }
    SettingsRow(label: "Лицензия") { Link("MIT ↗", url: ...) }
    SettingsRow(label: "Исходный код") { Link("github.com/unison ↗", url: ...) }
  }
  .padding(.vertical, 6)
  .background(LiquidGlassPanel(radius: 14))
  .frame(width: 560, height: 540)
}
```

**`SettingsRow.swift`** (component): two-column layout `HStack { label (with optional icon + hint stacked) Spacer trailingContent }` matching `.row` style.

**`InlineButton.swift`** (component): smaller bordered button with optional spinner.

**Auto-save behavior:**
- Every binding mutation in the view flows through ViewModel setters, which call `onChange(settings)` (already exists).
- `SettingsViewModel` exposes `@ObservationIgnored private var lastSavedSentinel: AnyHashable` updated on each change.
- A `SaveIndicatorController` watches `lastSavedSentinel` via `onChange(of:)` and toggles `isShown` for 1.6s.

**Tests** (`Tests/UnisonDomainTests/SettingsViewModelTests.swift` — extend):
- Setting API key calls keychain.saveAPIKey and triggers onChange.
- Hotkey assignment serializes/deserializes to UserDefaults key (use an in-memory `UserDefaults(suiteName:)` for tests).
- `availableInputs`/`availableOutputs` exclude BlackHole devices (already covered).

#### 3.4 — Transcript (`Sources/UnisonUI/Views/TranscriptView.swift` — replace)

Floating, draggable, bottom-center, always-on-top. Per DESIGN §12.3.

**TranscriptViewModel additions:**
- `var bubbleScale: Double = 1.0` (XS=0.75 ... XL=1.3) — bound to size slider in settings popover.
- `var originalMixVolume: Double` — projected from `Settings.originalMixVolume`. Pipe back through `Composition` so changes propagate to the mixer in real time. (The volume slider in the transcript settings popover is the same volume — so set up two-way binding to `SettingsViewModel.originalMixVolume`. Simpler: inject a `Settings` `@Observable` shared model wrapper, OR have `TranscriptViewModel` hold a closure `onVolumeChange` and listen for changes via the existing AppDelegate observation.)
- `var isHidden: Bool` — collapsed (bubbles list hidden, only pill visible).
- `var showStopConfirmation: Bool`.
- `var bubbleGroups: [BubbleGroup]` — computed via `TranscriptGrouper.group(entries:languagePair:)`.

**View structure:**
```
VStack(spacing: 10) {
  if !isHidden { BubblesList(groups: bubbleGroups, scale: bubbleScale) }
  ControlPill(
    isActive: orchestrator.state.isActive,
    elapsedSeconds: elapsedSeconds,
    onSettings: toggleSettingsPopover,
    onToggleHidden: { isHidden.toggle() },
    onStop: { showStopConfirmation = true }
  )
  // settings popover anchored above pill
}
.frame(width: panelWidth, alignment: .center)
.confirmationDialog (".stopConfirmation") { ... }
```

**`ControlPill.swift`** (component): pill-shaped HStack with status dot, mono timer, separator, gear button (toggles settings popover), text button "Скрыть"/"Показать", stop icon button.
- Backed by `LiquidGlassPanel(cornerRadius: 999)`.
- Drag handled at panel level (NSWindow movable by background — see Phase 5).

**`TranscriptSettingsPopover.swift`** (component): glass mini-panel with two NeutralSliders:
- "Размер транскрипта" — discrete A label (XS/S/M/L/XL) computed via `Math.round(value)` then mapped.
- "Громкость оригинала" — 0–100% int.
- Anchored above pill via `.popover(isPresented:)` (NSPopover-backed) OR rendered as overlay aligned `.bottom` to pill if popover is glitchy. Prefer overlay.

**Stop modal:**
- `.alert("Остановить перевод?", isPresented: $showStopConfirmation)` with `Button("Отмена", role: .cancel)` + `Button("Остановить", role: .destructive)` — standard SwiftUI alert; the design's custom glass modal would require a custom dialog component. Use SwiftUI alert as v1; revisit if visual fidelity demanded.

**`BubbleViewModel`** value type (in `UnisonUI/TranscriptGrouping.swift`):
```
struct BubbleViewModel: Identifiable, Equatable {
  let id: UUID
  let speaker: Speaker
  let primaryText: String
  let secondaryText: String
  let isFirstInGroup: Bool
  let isLastInGroup: Bool
  let isLive: Bool
}
struct BubbleGroup: Identifiable, Equatable {
  let id: UUID  // first bubble id
  let speaker: Speaker
  let bubbles: [BubbleViewModel]
}
struct TranscriptGrouper {
  static let splitThreshold = 240
  static let visibleLimit = 3
  static func group(entries: [TranscriptEntry], languagePair: LanguagePair?) -> [BubbleGroup]
}
```

Algorithm:
1. Project each `TranscriptEntry` into primary/secondary based on speaker.
2. Walk entries; runs of same speaker form a group.
3. For each entry, split primary into ≤240-char chunks at sentence boundaries (regex `[^.!?]+[.!?]+\s*`). Project secondary proportionally (split into N=max(primaryChunks, secondaryChunks) chunks; pad with last chunk).
4. Set `isFirstInGroup` true on first bubble of group, `isLastInGroup` true on last.
5. Drop oldest groups until count ≤ 3 (caller decides if they want the pruning or a `.fadeOut` transition).
6. Mark last bubble of the last group as `.isLive` if `orchestrator.state.isActive` AND last entry timestamp is within 2.5s of now (driven by `TimelineView`).

**Tests** (`Tests/UnisonDomainTests/TranscriptGroupingTests.swift` — new):
- Single short entry → one group with one bubble, `primary == originalText` for me, `primary == translatedText` for peer.
- Two consecutive me entries → one group with two bubbles, second is `isLastInGroup`.
- Me followed by peer → two groups.
- 250-char entry → split into 2 bubbles, both `isFirstInGroup` false on second.
- Long entry of mixed primary/secondary lengths uses sentence boundary split.
- More than 3 groups → only last 3 returned.

#### 3.5 — Onboarding/Settings/Transcript composition file `Sources/UnisonUI/Views/AboutView.swift` (new optional)
- Mini view shown from Settings's "О приложении" link OR from a right-click on the menubar logo. Defer to v2 if scope tight — DESIGN.md doesn't require it for shipping.

---

### Phase 4 — Menubar Icon States

Files to update/create in `Sources/UnisonApp/`:

#### 4.1 — `MenubarIcons.swift` (new)
- Renders four `NSImage` variants from `UnisonLogoShape` (Phase 1):
  - `idleTemplate` — 22×22, full logo, **isTemplate = true** (gets tinted by AppKit to match menubar).
  - `pausedTemplate` — 22×22, logo without voice streams, **isTemplate = true**.
  - `active` — 22×22, full logo drawn in `DesignColor.active` (cyan), **isTemplate = false** so cyan survives.
  - `error` — 22×22, full logo in `DesignColor.error` (coral) with a 7×7 dot drawn in the top-right corner, **isTemplate = false**.
- Renderer helper:
  ```
  func renderLogoImage(size: CGSize, showsVoiceStreams: Bool, fill: NSColor, badge: Bool, isTemplate: Bool) -> NSImage
  ```
  Uses `NSImage(size:flipped:drawingHandler:)` with a closure that draws the logo path via `NSBezierPath` mirroring `UnisonLogoShape` coordinates (re-implement; SwiftUI Path isn't reachable here).
- Caches images statically (cheap).

#### 4.2 — Update `StatusItemController.swift`

Replace:
```
button.image = NSImage(systemSymbolName: "globe", ...)
```
with:
```
button.image = MenubarIcons.idleTemplate
```

Add:
- `enum IconState { case idle, active, paused, error }`
- `func setIconState(_ state: IconState)` — updates `button.image` to corresponding variant.
- For `.active`, start a `Timer.publish(every:0.8, on:.main, in:.common)` that toggles button alpha 1.0 ↔ 0.7 to mimic the CSS pulse. Stop on state change away from active.
- Wire the popover content to use the new `PopoverView` with proper `onOpenSettings` callback that drives a future `SettingsWindowController.show()` (see 5.3).

#### 4.3 — Right-click / context menu
Per DESIGN §5.22:
- Right-click or Cmd+click: NSMenu with items Start/Stop, Show transcript, Settings…, About, Quit.
- Attach via `statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp, .otherMouseUp])` and check `NSApp.currentEvent?.type` in handler.
- Items wired to closures on `StatusItemController`; the controller calls into `Composition` (Quit) or window controllers (Transcript, Settings, About).

---

### Phase 5 — Wiring & Window Controllers

#### 5.1 — Onboarding window
`Sources/UnisonApp/OnboardingWindowController.swift` — update:
- Window size now 480×640 (per design; height includes footer with progress).
- `styleMask = [.titled, .closable, .fullSizeContentView]`; `titlebarAppearsTransparent = true`; `titleVisibility = .hidden`; `isMovableByWindowBackground = true`.
- Add a hosting controller for the new `OnboardingView`. Inject `onDismiss` closure that calls `hideIfDone()` after the user clicks "Готово" or the X button.
- `hideIfDone()` already exists; keep.

#### 5.2 — Transcript window
`Sources/UnisonApp/TranscriptWindowController.swift` — update:
- Replace fixed `NSRect(x:100,y:100,w:400,h:480)` with computed bottom-center placement on the **main display** at width `min(720, max(520, mainScreen.frame.width * 0.6))`.
- `styleMask: [.borderless, .nonactivatingPanel]` — borderless to avoid macOS title bar entirely; the design has none.
- `level = .floating`; `collectionBehavior = [.canJoinAllSpaces, .stationary]` so it persists across spaces.
- `isMovableByWindowBackground = true`; `hasShadow = true`.
- `backgroundColor = .clear` so transparent areas (between bubbles) actually show through.
- Hosting view: `TranscriptView` with `Composition.transcriptVM`.
- New: `show(over screen: NSScreen)` — re-position on screen change.

#### 5.3 — Settings window (new)
`Sources/UnisonApp/SettingsWindowController.swift` — new:
- `NSWindow` 560×540 + title bar, `titlebarAppearsTransparent = true`, custom hosting `SettingsView` from `UnisonUI`.
- Public `show()` and `hide()`.
- Stored in `AppDelegate` like the other two.
- Triggered from:
  - Gear button in PopoverView (via `StatusItemController` callback closure)
  - Menu item in StatusItem context menu
  - Hotkey (if user defines one in v2)

#### 5.4 — `HotkeyService.swift` (new)
`Sources/UnisonApp/HotkeyService.swift`:
- Carbon-based hotkey registration. Public API:
  ```
  @MainActor public final class HotkeyService {
    public init() {}
    public func register(id: HotkeyID, keyCode: UInt32, modifiers: UInt32, handler: @MainActor @escaping () -> Void) throws
    public func unregister(id: HotkeyID)
    public func unregisterAll()
  }
  public struct HotkeyID: Hashable { let raw: UInt32 }
  ```
- Internal `EventHotKeyRef` map keyed by `HotkeyID`.
- Install Carbon event handler once via `InstallEventHandler` for `kEventClassKeyboard, kEventHotKeyPressed`; dispatch by id to stored handler closure.
- AppDelegate creates one instance, reads current hotkey strings from `SettingsViewModel`, parses via `HotkeyParser` (UnisonUI), and registers for:
  - Start/Stop (`⌃⌥U` default) → `orchestrator.start/stop` depending on state
  - Show transcript (`⌃⌥T` default) → `transcriptWindow.show()`

#### 5.5 — `Composition.swift` updates
- Inject `installer` into `SettingsViewModel`.
- Inject `keychain` into `SettingsViewModel`.
- Inject `installer` and `permissions.openSystemSettings(.microphone)` callback into Onboarding flows (already there).
- Add `SettingsStore` extension to load/save hotkeys + autostart + hideMenu toggles.
- Wire `popoverVM.settings` two-way binding: when settings update from settings window, the popover reflects new lang pair / mode. Currently `Composition.init` already does `popVM.settings = s` inside `onChange`. Keep, extend to also push to `TranscriptViewModel.bubbleScale` and `originalMixVolume`.

#### 5.6 — `AppDelegate.swift` updates
- Instantiate `SettingsWindowController(viewModel: composition.settingsVM)` in `applicationDidFinishLaunching`.
- Instantiate `HotkeyService`; register configured hotkeys.
- Wire `StatusItemController` to use:
  - `onOpenSettings: { [weak self] in self?.settingsWindow.show() }`
  - `onShowTranscript: { [weak self] in self?.transcriptWindow.show() }`
  - `onQuit: { NSApp.terminate(nil) }`
- Replace `setActiveIcon(_:)` with new `setIconState(...)`. Map orchestrator state → IconState:
  - `.idle` → `.idle`
  - `.connecting` / `.translating` → `.active`
  - `.reconnecting` → `.active` (or a future `.paused`?) — for now treat as `.active` with the pulse continuing.
  - `.error` → `.error`
  - Paused (when transcript is hidden but session active) → maps to `.paused`. Add a flag in AppDelegate that combines orchestrator state + transcriptWindow visibility.
- When `SettingsViewModel` updates hotkeys: re-register via HotkeyService. Observe via `withObservationTracking` same way orchestrator state is observed today.

---

### Phase 6 — Tests for new UI logic

Add to `Tests/UnisonDomainTests/` (target already depends on UnisonUI):

| Test file | What it covers |
|---|---|
| `UnisonLogoShapeTests.swift` | Path generation correctness (count of subpaths, bounding box). |
| `LanguagePickerFilterTests.swift` | `filterLanguages(_:query:)` matches by name and code, case-insensitive. |
| `NeutralSliderTests.swift` | `sliderFillOpacity(for:)` returns 0.12+0.73*fraction, clamps boundary, mirror behavior of the JS `updateSliderFill`. |
| `HotkeyParserTests.swift` | `formatHotkey(modifiers:keyCode:)` returns `⌃⌥U` style; requires at least one modifier; Esc returns nil. Round-trip serialize/deserialize through UserDefaults. |
| `TranscriptGroupingTests.swift` | All 6+ cases from §3.4 above. |
| `OnboardingViewModelTests.swift` (extend) | New `validateAPIKey` / error transitions. |
| `PopoverViewModelTests.swift` (extend) | `elapsedSecondsString` formatting, `statusKind` matrix, `isLanguagePairValid`. |
| `SettingsViewModelTests.swift` (extend) | API key flow with mock keychain, hotkey serialization, reinstall calls installer. |

All tests use Swift Testing (`@Test`, `#expect`). Match existing style. Keep mocks in `Tests/UnisonDomainTests/Mocks/` (folder exists).

Final verification:
1. `scripts/test.sh` — all tests pass (target 100+ tests, was 93).
2. `swift build -c release` succeeds.
3. Manual smoke (instructions for executor):
   - Launch app: status item shows the U logo template.
   - Click status item: popover opens with new Aurora glass design at 340pt width.
   - Switch Call/Listen, change languages, observe warn state when both equal.
   - Click gear icon: Settings window opens (560×540).
   - Open Settings → BlackHole → Переустановить: verify installer kicks off.
   - Set hotkey `⌃⌥U`: dismiss settings, press `⌃⌥U` globally → orchestrator toggles.
   - Onboarding window opens on first launch if any step incomplete.
   - When session active: status item icon switches to cyan pulsing logo; transcript window appears bottom-center.
   - Bubbles appear; long messages split at 240 chars; >3 groups prunes oldest with fade-out.
   - Settings popover within transcript: change size → bubbles scale; change volume → mixer updates.
   - Stop button → confirmation dialog → confirm → session stops, transcript hides.

---

## 3. Sequencing & Dependencies Summary

```
Phase 1 (tokens + logo + glass + aurora)
    ├──> Phase 2 (components — each can be parallelized once tokens land)
    │       ├── StatusDot, IconButton, PrimaryGlassButton, SectionHeader, Toggle, SaveIndicator, WarnRow, ErrorRow
    │       ├── NeutralSlider (depends on opacity helper)
    │       ├── SegmentedToggle, SecretInput
    │       ├── HotkeyRecorder (depends on HotkeyParser)
    │       ├── LanguagePickerDropdown + LanguageBar + FlagText (depends on Language+Flag)
    │       └── Bubble + BubbleGroupView (depends on TranscriptGrouper)
    └──> Phase 3 (screens — each is a tree of components)
            ├── PopoverView   (LanguageBar, SegmentedToggle, PrimaryGlassButton, StatusDot, WarnRow)
            ├── OnboardingView (StepCard, ErrorRow, SecretInput, PrimaryGlassButton, AuroraBackground)
            ├── SettingsView   (SettingsRow, all of the above, dropdowns)
            └── TranscriptView (BubbleGroupView, ControlPill, TranscriptSettingsPopover)

Phase 4 (menubar icons) parallel to Phase 3 — depends on UnisonLogoShape & MenubarIcons renderer.

Phase 5 (wiring) — depends on Phases 3 + 4.

Phase 6 (tests) — incrementally written alongside Phases 1-3 (every pure helper has tests immediately).
```

A natural commit cadence:
- C1: Phase 1 + logo tests
- C2: Phase 2 atoms (no screens yet wired)
- C3: PopoverView + StatusItem rewire (smallest visible win)
- C4: OnboardingView replacement
- C5: SettingsView + SettingsWindowController + HotkeyService
- C6: TranscriptView + grouping
- C7: Polish, final wire-up, smoke tests verified

---

## 4. Out of Scope (defer to follow-up)

- **About modal** — DESIGN.md shows a mock; not required for first ship.
- **macOS 26 Liquid Glass APIs** — explicit guard remains macOS 14+.
- **Custom font bundling (DM Sans / IBM Plex Mono)** — system fallback documented; revisit later.
- **`feDisplacementMap` refraction** — explicitly omitted; the conic-rim + specular gradient suffice for v1.
- **Settings auto-launch (LaunchAtLogin)** — toggle exists in UI but actual `SMAppService.mainApp.register()` implementation can be deferred behind a TODO with the toggle persisted only.
- **System Settings deep-link from onboarding mic error** — `permissions.openSystemSettings(.microphone)` already in protocol; verify its implementation in `MacPermissions` uses the new `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone` URL.

---

## 5. Files to Touch — Master List

### New files (`Sources/UnisonUI/`)
- `Design/Colors.swift`
- `Design/Fonts.swift`
- `Design/Spacing.swift`
- `Design/AnimationTokens.swift`
- `Design/UnisonLogoShape.swift`
- `Design/LiquidGlassPanel.swift`
- `Design/AuroraBackground.swift`
- `Components/StatusDot.swift`
- `Components/IconButton.swift`
- `Components/PrimaryGlassButton.swift`
- `Components/SegmentedToggle.swift`
- `Components/PillToggle.swift`
- `Components/NeutralSlider.swift`
- `Components/SecretInput.swift`
- `Components/HotkeyRecorder.swift`
- `Components/SaveIndicator.swift`
- `Components/WarnRow.swift`
- `Components/ErrorRow.swift`
- `Components/SectionHeader.swift`
- `Components/LanguagePickerDropdown.swift`
- `Components/LanguageBar.swift`
- `Components/FlagText.swift`
- `Components/Bubble.swift`
- `Components/BubbleGroupView.swift`
- `Components/StepCard.swift`
- `Components/SettingsRow.swift`
- `Components/InlineButton.swift`
- `Components/ControlPill.swift`
- `Components/TranscriptSettingsPopover.swift`
- `Extensions/Language+Flag.swift`
- `Hotkey.swift` (value type)
- `HotkeyParser.swift`
- `TranscriptGrouping.swift`

### Replaced files (`Sources/UnisonUI/Views/`)
- `Views/PopoverView.swift`
- `Views/OnboardingView.swift`
- `Views/SettingsView.swift`
- `Views/TranscriptView.swift`

### Modified files (`Sources/UnisonUI/ViewModels/`)
- `PopoverViewModel.swift` — additive computed properties; remove private `flag(_:)` (moved to extension).
- `OnboardingViewModel.swift` — `StepStatus`, `apiKeyDraft`, `validateAPIKey`.
- `SettingsViewModel.swift` — new dependencies (keychain, installer), new state (apiKey, hotkeys, toggles, reinstall status).
- `TranscriptViewModel.swift` — `bubbleScale`, `isHidden`, `showStopConfirmation`, `bubbleGroups` computed.

### New files (`Sources/UnisonApp/`)
- `MenubarIcons.swift`
- `HotkeyService.swift`
- `SettingsWindowController.swift`
- `Glue/DropdownPopover.swift` (optional helper if settings dropdowns escape window via NSPopover)

### Modified files (`Sources/UnisonApp/`)
- `Composition.swift` — wire new VM dependencies; build hotkey wiring.
- `AppDelegate.swift` — instantiate SettingsWindowController + HotkeyService; new icon-state callback.
- `StatusItemController.swift` — new icon states, context menu, callback closures.
- `TranscriptWindowController.swift` — borderless panel, bottom-center positioning, level/collection behavior.
- `OnboardingWindowController.swift` — transparent title bar, fixed dimensions.

### Modified files (`Resources/`)
- `Info.plist` — no required additions; verify `LSUIElement` remains and that no resource keys conflict.

### New test files (`Tests/UnisonDomainTests/`)
- `UnisonLogoShapeTests.swift`
- `LanguagePickerFilterTests.swift`
- `NeutralSliderTests.swift`
- `HotkeyParserTests.swift`
- `TranscriptGroupingTests.swift`

### Extended test files
- `PopoverViewModelTests.swift`
- `OnboardingViewModelTests.swift`
- `SettingsViewModelTests.swift`

---

### Critical Files for Implementation

These are the 5 files most central to executing this plan correctly. An executor should read these first:

- `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/docs/design/DESIGN.md`
- `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/Sources/UnisonApp/Composition.swift`
- `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/Sources/UnisonApp/StatusItemController.swift`
- `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/Sources/UnisonUI/ViewModels/PopoverViewModel.swift`
- `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/design/popover-final/index.html`

---

**Note on file output:** I am in read-only planning mode and cannot save this to disk. Please copy the markdown above into `/Users/nvzamuldinov/projects/unison/.claude/worktrees/inspiring-rosalind-569c1a/docs/superpowers/plans/2026-05-20-ui-integration.md` yourself, or hand this conversation to an implementer agent that has write access. The plan is self-contained and ready to drive execution.
