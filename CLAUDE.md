# Unison — architecture notes

macOS 26 Tahoe-only menubar app. Real-time speech translation for video calls.

## Knowledge base

- **[Audio pipeline](docs/audio-pipeline.md)** — model behavior, our chain,
  known bugs, AGC, pacing, diagnostic env-vars, pacing-eval harness. Read
  this before touching anything in `Sources/UnisonAudio/` or `Sources/UnisonTranslation/`.

## Liquid Glass — two backends behind one API

Every glass surface in the UI is rendered via one of two mechanisms:

- **AppKit windows** (Onboarding, Settings, Diagnostic): wrap content in
  `GlassHostingViewController` → `NSGlassEffectView`. **Compositor-managed
  and live** — refreshes every frame as behind-window content moves.
- **SwiftUI views** (transcript bubbles, control pill, primary button,
  popover): go through `.liquidGlass(...)` → `LiquidGlassPanel` →
  `.glassEffect(in:)`. **Static between view-tree redraws** — Apple's
  SwiftUI glass only re-samples when SwiftUI re-renders.

The transcript window is the only one **without** panel-level glass — it's
a transparent floating `NSPanel`; each bubble paints its own glass.

Corner radii must match the AppKit clip and the SwiftUI glass shape:

| Surface          | Radius |
| ---------------- | ------ |
| Onboarding card  | 22 (`OnboardingLayout.windowCornerRadius`) |
| Settings card    | 10 (system `.titled` window) |
| Diagnostic card  | 18 |
| Menubar popover  | 24 |
| Stop modal       | 18 |
| Transcript bubble| `UnevenRoundedRectangle` with 18pt base + speaker tail |
| Control pill     | `Capsule` |

## Window machinery

**Transparent borderless cards** (Onboarding, Diagnostic, Transcript,
Menubar popover): `isOpaque = false`, `backgroundColor = .clear`,
`hasShadow = true`. The visible chrome is the `NSGlassEffectView` /
SwiftUI `.liquidGlass`. Layer-clip the content view's CALayer to the
same corner radius — otherwise the window shadow leaks dark
triangles into the rounded corners.

**Settings** uses standard `.titled` chrome with traffic lights;
content extends behind the (transparent) titlebar via
`.fullSizeContentView`. SwiftUI scroll edges clip cleanly via
`.scrollEdgeEffectStyle(.hard, for: .top)`.

**Menubar popover** is a custom `MenubarPanel : NSPanel`, not
`NSPopover` (no arrow, reliable auto-dismiss). Positioned below the
status-item icon. `canBecomeKey = true` so `resignKey` fires when
the user clicks outside → `orderOut(nil)`. 200ms debounce on
`togglePopover` so clicking the icon while the panel is open closes
it (rather than re-opening via the resignKey → click-action race).
`forceVisible = true` suppresses auto-dismiss in
`UNISON_FORCE_STATE=popover-open` harness mode.

**Transcript drag** runs entirely through `WindowDragHandle` (manual
`mouseDown`/`mouseDragged`/`mouseUp`). AppKit's
`mouseDownCanMoveWindow` auto-drag doesn't fire for
`nonactivatingPanel`s. The pill's non-button elements (dot, timer,
separator) sit in a `Group { … }.allowsHitTesting(false)` so clicks
fall through to the drag handle. Everywhere else on the transparent
panel is hit-test transparent
(`panel.isMovableByWindowBackground = false`).

## Test mode

`PopoverViewModel.startTest()` starts an orchestrator session with
`mode: .test`. `TranscriptViewModel.isTestMode` flips when
`orchestrator.state.activeMode == .test` and propagates to:

- `Bubble`: tint and border switch to `UnisonColors.warn` (#ffc060)
- `ControlPill.StatusDot`: state flips from `.active` to `.warn`
  (cyan → yellow)

## Debug / harness env vars

`UNISON_FORCE_STATE` (parsed once at launch by `Composition`):

- `onboarding-done` / `transcript-demo` — Process Tap audio capture
  preseeded, keychain preseeded, mocked permissions
- `popover-open` — opens the popover at launch and disables
  auto-dismiss; used by the Tart screenshot harness
- `start-translation` / `start-stop-start` — drives integration tests
  through the production codepath
- `transcript-demo` — populates the transcript with synthetic bubbles
  via `previewElapsedSeconds`
