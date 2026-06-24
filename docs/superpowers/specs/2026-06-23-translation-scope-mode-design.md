# Translation scope mode (blocklist ↔ allowlist) — design

Status: draft  •  Author: nvzamuldinov  •  Date: 2026-06-23

> **Post-implementation note (2026-06-23).** Two parts of the original design
> were revised during live testing — see `docs/audio-pipeline.md` → "Process
> Tap scope":
> - The **dynamic re-resolution** (a `kAudioHardwarePropertyProcessObjectList`
>   listener re-pushing the tap description live) was **removed** — it hung Stop
>   and crashed the app. Scope is resolved **once at start()**; an app must be
>   producing audio when Start is pressed.
> - Exclusion/inclusion matching is **helper-aware**: many apps emit audio from
>   a helper process (Yandex `…music.helper`, Dia `company.thebrowser.browser.helper`).
>   Matched by CoreAudio bundle ID (exact or `target.` child) **or** executable
>   path inside the app bundle.

## Context

Unison translates system audio captured via a CoreAudio Process Tap. Today
the only way to shape *what* gets translated is a **blocklist**: a list of
bundle IDs to exclude from the tap (`Settings.excludedTapBundleIDs`), built
with `CATapDescription(monoGlobalTapButExcludeProcesses:)`. The tap mutes
what it captures (`.mutedWhenTapped`) and Unison replays translation + a
quiet original, so an *excluded* app — never tapped — plays at its original
volume.

Users want the inverse for calls: instead of listing everything to ignore,
pick **only** the app(s) to translate (e.g. just the conferencing app) and
leave everything else untouched. The two are mutually exclusive, so the
feature is a **mode toggle** with one active app list at a time.

CoreAudio supports this symmetrically: `CATapDescription` offers
`initMonoMixdownOfProcesses:` (tap *only* the listed processes) alongside
`initMonoGlobalTapButExcludeProcesses:` (tap everything *except*). The mute
semantics fall out for free — `.mutedWhenTapped` only affects what is
tapped — so each mode mutes/translates exactly its target set and leaves the
rest at 100%.

Related prior work in this branch:
- Picker now lists all installed apps (not just audio-active ones).
- `ProcessTapCapture` keeps its exclusion list current via a
  `kAudioHardwarePropertyProcessObjectList` listener
  (`installProcessListListener` / `refreshTapExclusions`), updating the live
  tap through `kAudioTapPropertyDescription`. This listener generalizes to
  both modes and is what makes allowlist usable (an included app gets added
  to the tap as soon as it starts producing audio).

## Goals

1. A **mode toggle** "Что переводить" with two mutually-exclusive options:
   - **Всё, кроме выбранных** (blocklist) — current behavior, the default.
   - **Только выбранные** (allowlist) — translate only the chosen apps.
2. **Two independent app lists** — switching the toggle preserves each
   mode's selection; it does not reinterpret the same list.
3. In allowlist mode, **block starting translation while the list is empty**
   (disabled Start + a clear hint), so the user never ends up with
   translation "on" but silent.
4. Existing users upgrade with **zero behavior change** (default = blocklist,
   existing excluded list preserved).
5. The dynamic process-list listener keeps the live tap correct in **both**
   modes.

## Non-goals (YAGNI)

- No quick mode switch in the menubar popover — Settings only.
- No auto-detection of the conferencing app.
- No per-app volume control.
- No change to the outbound (mic → peer) path.

## Design

### Modes & tap semantics

| Mode | Tap built with | `.mutedWhenTapped` mutes | Result |
| --- | --- | --- | --- |
| `allExcept` (blocklist) | `monoGlobalTapButExcludeProcesses: resolved + self` | everything except chosen + self | chosen apps play at 100%, rest translated |
| `onlySelected` (allowlist) | `monoMixdownOfProcesses: resolved` | only the chosen apps | chosen apps translated, rest at 100% |

Self-process is excluded in blocklist mode (anti-feedback) as today. In
allowlist mode we never tap ourselves, so no self-handling is needed.

### Data model + migration (`Sources/UnisonDomain/Settings.swift`)

Add to `UnisonDomain`:

```swift
public enum TapScopeMode: String, Codable, Sendable, CaseIterable {
    case allExcept       // blocklist — translate everything except the list
    case onlySelected    // allowlist — translate only the list
}
```

Add to `Settings`:
- `var tapScopeMode: TapScopeMode` — default `.allExcept`.
- `var includedTapBundleIDs: [String]` — default `[]` (the allowlist's own
  list). `excludedTapBundleIDs` stays as the blocklist's list.

Codable: decode both new keys with `decodeIfPresent` and the defaults above,
mirroring the existing `excludedTapBundleIDs` handling. Old settings JSON
(no new keys) ⇒ `allExcept` + empty included list ⇒ identical behavior.

### TapScope + `ProcessTapCapture` (`Sources/UnisonAudio/ProcessTapCapture.swift`)

Introduce a runtime scope value type in `UnisonAudio` (the capture concept;
built in `Composition`, which already imports `UnisonAudio`). The persisted
`TapScopeMode` lives in `UnisonDomain` with `Settings`; `TapScope` is the
resolved runtime pairing of mode + the active list:

```swift
public enum TapScope: Sendable, Equatable {
    case allExcept([String])     // bundle IDs to exclude
    case onlySelected([String])  // bundle IDs to include
}
```

- Change the production initializer from
  `excludedBundleIDsProvider: @Sendable () -> [String]` to
  `scopeProvider: @Sendable () -> TapScope`. Keep a static-list init for
  tests.
- Generalize resolution: a single function maps the active scope's bundle
  IDs → live `AudioObjectID`s (skipping apps with no audio object yet, as
  today). Blocklist also appends self.
- A single `makeTapDescription(for objectIDs:)`-style helper builds the right
  `CATapDescription` per mode (`monoMixdownOfProcesses:` vs
  `monoGlobalTapButExcludeProcesses:`), sets `isPrivate = true` and
  `muteBehavior = .mutedWhenTapped`. Used by both `createTap()` and
  `refreshTapExclusions()`.
- The existing listener stays installed whenever the active list is
  non-empty (both modes benefit). Rename the now mode-neutral members
  (`processObjectIDs`, `resolveExcludedProcessObjects`, `refreshTapExclusions`)
  to mode-neutral names (e.g. `tappedProcessObjectIDs`, `resolveTapObjectIDs`,
  `refreshTapDescription`).

Defense in depth: `onlySelected([])` ⇒ `monoMixdownOfProcesses: []` taps
nothing (silence), which is harmless even though the start gate (below)
prevents reaching it.

### Start gate for empty allowlist (`Sources/UnisonUI/ViewModels/PopoverViewModel.swift`)

`StartBlockedReason` currently has `.micPermissionRequired` and
`.blackHole2chMissing`, surfaced via `canStart` → `canStartStrict` and the
primary button's `.disabled(!state.isActive && !canStartStrict)`.

- Add `case noAppsToTranslate`.
- `startBlockedReason` returns it when
  `settings.tapScopeMode == .onlySelected && settings.includedTapBundleIDs.isEmpty`.
- The view maps it to a hint, e.g. «Выберите приложения для перевода» (same
  surface that renders the other blocked reasons).

This gate only applies to modes that capture peer audio (`.call` / `.listen`).
`.test` mode (mic-only) is unaffected — confirm it bypasses the scope gate.

### UI — Settings (`ExcludedAppsSection` → `AppScopeSection`)

- A segmented `Picker` bound to `tapScopeMode`, labeled «Что переводить»,
  options «Всё, кроме выбранных» / «Только выбранные».
- The list and copy below adapt to the active mode:
  - `allExcept`: header «Не переводить звук из:», empty hint as today.
  - `onlySelected`: header «Переводить звук только из:», empty hint
    «Выберите приложения — остальное Unison не трогает».
- The list shown is the active mode's list; add/remove edits only that list.
- The picker (`ExcludedAppsPicker` → rename `AppScopePicker`) is shared;
  `already` is the active list. No behavioral change to the picker itself.
- `SettingsViewModel` gains `tapScopeMode` get/set and an
  `includedTapBundleIDs` binding alongside the existing excluded one.

### Wiring (`Sources/UnisonApp/Composition.swift`)

The `ProcessTapCapture` provider builds a `TapScope` from settings:

```swift
let s = settingsStoreRef.load()
return s.tapScopeMode == .onlySelected
    ? .onlySelected(s.includedTapBundleIDs)
    : .allExcept(s.excludedTapBundleIDs)
```

Re-read on every `start()`, so a mode/list change takes effect on the next
session (unchanged from today's contract).

## Testing

Unit-testable (no hardware):
- `Settings` Codable round-trip with the new fields; **migration** from old
  JSON lacking the keys ⇒ `allExcept` + `[]`.
- A pure selector `bundleIDs(for: TapScopeMode, excluded:, included:) -> [String]`
  (or equivalent) returns the correct list per mode.
- `PopoverViewModel.startBlockedReason` ⇒ `.noAppsToTranslate` exactly when
  allowlist + empty; `canStartStrict` false in that case; and *not* blocked
  in blocklist mode with an empty list.
- Existing `SettingsView` snapshots updated for the new segmented control.

Not unit-testable (CoreAudio + live audio, manual verification):
- Choosing `monoMixdownOfProcesses:` vs `monoGlobalTapButExcludeProcesses:`
  and the actual mute/translate behavior per mode.

## Copy (Russian, minimal)

| Surface | Text |
| --- | --- |
| Segmented label | Что переводить |
| Mode A | Всё, кроме выбранных |
| Mode B | Только выбранные |
| Section header (A) | Не переводить звук из: |
| Section header (B) | Переводить звук только из: |
| Empty hint (B) | Выберите приложения — остальное Unison не трогает |
| Start blocked hint | Выберите приложения для перевода |

## Open questions

None.
