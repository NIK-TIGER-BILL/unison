# Process Tap integration — design

Status: draft  •  Author: nvzamuldinov  •  Date: 2026-05-27

## Context

Unison currently captures meeting audio by reading from **BlackHole 16ch**,
a 16-channel virtual audio device the user installs via a bundled `.pkg`
and then manually configures as Zoom's output device. This works but is
heavy on UX:

- Two separate BlackHole installers in onboarding (2ch for outbound
  virtual microphone, 16ch for inbound capture)
- User must change Zoom's playback output to BlackHole 16ch
- All system audio routes there, not just the meeting
- Without active reader, the user does not hear the meeting at all

macOS 14.2+ exposes **CoreAudio Process Tap**
(`AudioHardwareCreateProcessTap` + `CATapDescription`) — a first-class
API for capturing the audio output of one or more processes without any
virtual device. On macOS 26 Tahoe (Unison's target) the API is fully
available and `CATapMuteBehavior.mutedWhenTapped` lets us mute the
tapped source at the device level while we capture it, so we keep full
control of the mix the user hears.

This document specifies a **clean cutover** from BlackHole 16ch to
Process Tap for the inbound path. The outbound path (BlackHole 2ch as
virtual microphone) is unchanged; no public macOS API replaces it.

Source materials:
- Original tap-vs-BlackHole evaluation: [docs/superpowers/specs/2026-05-27-tap-vs-blackhole-benchmark-design.md](./2026-05-27-tap-vs-blackhole-benchmark-design.md)
- Smoke-run findings: [docs/superpowers/results/2026-05-27-smoke-run-known-issues.md](../results/2026-05-27-smoke-run-known-issues.md)
- `ProcessTapCapture` already exists in `Sources/UnisonAudio/`, added by
  the benchmark prototype; this spec wires it into production

## Goals

1. Replace `BlackHoleSinkCapture` with `ProcessTapCapture` in the
   production translation pipeline
2. Stop installing or requiring BlackHole 16ch on the user's system
3. User-controllable list of apps to **exclude** from translation (for
   background music, etc.) — default empty
4. User retains the existing "original volume" slider (the `.mutedWhenTapped`
   mode preserves mix control, identical to current BlackHole-based UX)
5. New TCC audio-capture permission is part of the onboarding `Audio setup`
   step, with a clear recovery path if denied
6. Existing users on the old architecture upgrade with no manual steps
   beyond accepting the TCC prompt on first translation start

## Non-goals

- Latency benchmarking of Tap vs BlackHole (was the original prototype's
  scope; not needed to ship — qualitative advantages of Tap are sufficient)
- Replacing BlackHole 2ch on the outbound path (no public API replacement)
- Removing BlackHole 16ch from the user's system (other apps may depend on it)
- Fallback to BlackHole 16ch when Process Tap fails (clean cutover, no
  dual-path)
- Hot-reload of excluded apps mid-session (apply on next Start)
- Multi-source dynamic re-tapping when new audio sources start during a
  session (snapshot at Start time)
- Localization of new UI copy beyond what current onboarding has

## Architecture

The inbound capture path is already abstracted in the orchestrator
through `peerCapture: any PeerAudioCapture`. The cutover is therefore
**one DI line change** in `Composition` plus the supporting code
adjustments around it.

```
Composition  (DI)
   ├─ peerCapture = ProcessTapCapture(             ← was BlackHoleSinkCapture(registry:)
   │      excludedBundleIDs: settings.excludedTapBundleIDs
   │   )
   │
   └─ TranslationOrchestrator → wireIncomingPipeline → AVAudioOutputMixer
      (no changes — `peerCapture` is used through the protocol)
```

The tap is configured as a **system-wide tap with exclusions**:

```swift
CATapDescription(
    monoGlobalTapButExcludeProcesses: [
        ourPID,                       // exclude self to avoid feedback
        userExcludedPIDs...           // settings.excludedTapBundleIDs → PIDs
    ]
)
desc.muteBehavior = .mutedWhenTapped  // mutes source device output while tapping
desc.isPrivate = true
```

While translation is active, every audio process except Unison and the
user's excluded list (Spotify, Apple Music, etc.) is muted at the
device layer. Our `AVAudioOutputMixer` plays the captured original
through the existing player node at the user-controlled gain (default
0.2) plus the translation through the other player node at gain 1.0,
to the user's default output. Latency profile is identical to the
current BlackHole 16ch setup (~20–30 ms end-to-end), because the
playback chain is unchanged.

When the user stops translation, the tap is destroyed and macOS
restores normal device-level output to the tapped processes.

## Component changes

### Modified

**`Sources/UnisonAudio/ProcessTapCapture.swift`**

- `init(excludedBundleIDs: [String] = [])` replaces `init(targetPID: pid_t)`.
- On `start()`:
  1. Resolve `[ourPID] + excludedBundleIDs.compactMap { NSWorkspace bundleID → PID }`.
     Apps from the excluded list that aren't currently running are silently
     skipped — they can't appear in the system tap anyway.
  2. Build `CATapDescription(monoGlobalTapButExcludeProcesses: pids)`.
  3. `desc.muteBehavior = .mutedWhenTapped`.
  4. The aggregate-device + IOProc setup is unchanged.

**`Sources/UnisonApp/Composition.swift`**

One-line change — instantiate `ProcessTapCapture(excludedBundleIDs:
settings.excludedTapBundleIDs)` instead of
`BlackHoleSinkCapture(registry:)`.

**`Sources/UnisonDomain/TranslationOrchestrator.swift`**

- Remove the `blackHole16chMissing` guard at line 165–169 and the
  corresponding error case from the `TranslationError` (or similarly
  named) enum.
- The rest of `wireIncomingPipeline` is unchanged.

**`Sources/UnisonSystem/BundledBlackHoleInstaller.swift`**

- The fetch/install loop runs **only for the 2ch package**. The 16ch
  release entry is no longer downloaded or installed.
- `DeviceVerifier.hasDevice(named:)` only verifies "BlackHole 2ch".

**`Sources/UnisonDomain/Settings.swift`**

- New field `public var excludedTapBundleIDs: [String] = []`.
- Codable round-trip via the existing Settings persistence.

**`Sources/UnisonUI/ViewModels/OnboardingViewModel.swift`**

The `.blackHole` step (enum case name preserved to avoid noisy churn in
unrelated UI code) becomes a two-sub-task step:

1. **Install virtual microphone** (BlackHole 2ch).
   Click → `installer.runBundledInstaller()` (now only 2ch).
2. **Allow audio capture** (Process Tap TCC).
   Click → create a throwaway `ProcessTapCapture(excludedBundleIDs: [])`
   then immediately `stop()` — the macOS TCC prompt fires on tap
   creation. On grant, sub-task ✓; on deny, sub-task ✗ with a deep
   link to System Settings.

The step is `completed` when both sub-tasks are ✓.

### New

**`Sources/UnisonAudio/AudioProcessRegistry.swift`** (~80 LoC)

Utility for enumerating CoreAudio audio processes. Both
`ProcessTapCapture` (for bundle ID → PID resolution) and the Settings
picker (for showing user a list of running audio apps) need this:

```swift
public struct AudioProcess: Sendable {
    public let pid: pid_t
    public let bundleID: String
    public let name: String
    public let iconPath: String?
    public let isProducingAudio: Bool
}

public enum AudioProcessRegistry {
    public static func runningAudioProcesses() -> [AudioProcess]
    public static func processObjectID(forBundleID id: String) -> AudioObjectID?
}
```

Implementation uses `kAudioHardwarePropertyTranslateBundleIDToProcessObject`
and `kAudioProcessPropertyIsRunning` (macOS 14.2+, all available on
Tahoe).

**`Sources/UnisonUI/Views/Settings/ExcludedAppsSection.swift`** (new file)

Settings section, placed after "Audio devices":

```
Не переводить звук из:
  [📷 Spotify]                                 ×
  [📷 Apple Music]                             ×
  + Добавить

(If empty — single-line hint:
 "Музыкальные плееры и другое — Unison будет их пропускать")
```

`+ Добавить` opens a sheet with `AudioProcessRegistry.runningAudioProcesses()`,
sorted alphabetically by app name, with icons from
`NSWorkspace.shared.icon(forFile:)`. Selecting an item adds its
bundle ID to `settings.excludedTapBundleIDs` and dismisses the sheet.
`×` removes the entry.

Changes to the excluded list during an active translation session do
not affect the running tap — a banner appears: «Изменения применятся
при следующем запуске перевода».

### Deleted

| File / symbol                                                                     | Action |
| --------------------------------------------------------------------------------- | ------ |
| `Sources/UnisonAudio/BlackHoleSinkCapture.swift`                                  | Delete file |
| `Tests/UnisonAudioTests/BlackHoleSinkCaptureTests.swift` (if exists)              | Delete file |
| `CoreAudioDeviceRegistry.findBlackHole16ch()`                                     | Delete method |
| `TranslationError.blackHole16chMissing` (or whatever the case is named)           | Delete case + all use sites |
| `BundledBlackHoleInstaller` 16ch fetch/install logic                              | Delete branches |
| `DeviceVerifier.hasDevice(named: "BlackHole 16ch")`                               | Delete check |
| Onboarding copy referring to "16ch"                                               | Update copy |
| `BlackHoleSinkCaptureTests` and related fixtures                                  | Delete |
| References to 16ch in `CLAUDE.md`, `README.md`, `scripts/vm-screenshot.sh` etc.   | Update text |

The `BlackHole16ch.driver` file in the user's `/Library/Audio/Plug-Ins/HAL/`
is **not** touched. Other macOS audio-routing apps may use it.

The `PeerAudioCapture` protocol stays as-is, even though it now has
only one implementation. Removing the protocol and inlining
`ProcessTapCapture` is a refactor outside this scope.

## Data flow

### When user clicks Start

1. `Composition` already instantiated `peerCapture =
   ProcessTapCapture(excludedBundleIDs: settings.excludedTapBundleIDs)`
2. `TranslationOrchestrator.start()` runs (no BH 16ch guard)
3. `wireIncomingPipeline(stream:)`:
   - `peerCapture.start()` resolves PIDs, creates the tap, IOProc fires,
     stream of `AudioFrame` begins
   - Splitter Task duplicates frames into
     - translation pipeline → STT/MT → translated frames →
       `outputMixer.playTranslated(...)` at volume 1.0
     - passthrough → `outputMixer.playOriginal(...)` at user-controlled
       gain (default 0.2)
4. Mixer plays into the system default output device
5. User hears `original × gain + translation × 1.0`

### When user clicks Stop

1. `peerCapture.stop()` tears down the tap, destroys aggregate device,
   releases the AU
2. macOS unmutes the tapped processes at the device layer
3. Mixer flushes, players stop
4. Source apps (Zoom, etc.) resume normal device output instantly

### When user changes excluded apps mid-session

The list snapshot was passed at `start()` time. Settings save persists
to UserDefaults; on the next `Start` click the new list is read. UI
shows a banner during the active session: «Изменения применятся при
следующем запуске перевода».

## UX

### Onboarding — "Audio setup" step

The step replaces (in user-visible terms) the current
"Install BlackHole" step. Internally the enum case
`OnboardingStepKind.blackHole` is preserved to avoid touching unrelated
UI plumbing; only the rendering and sub-task logic change.

```
┌─ Аудио ─────────────────────────────────┐
│                                          │
│  ☐ Виртуальный микрофон (BlackHole 2ch)  │
│     [Установить]                          │
│                                          │
│  ☐ Захват системного звука                │
│     [Разрешить]                           │
│                                          │
│   Продолжить                              │
│   (доступно когда оба ✓)                  │
└──────────────────────────────────────────┘
```

Behavior:

- **Sub-task 1** — Click "Установить" runs `installer.runBundledInstaller()`
  (now restricted to 2ch). Shows progress, ✓ on completion.
- **Sub-task 2** — Click "Разрешить" creates a throwaway
  `ProcessTapCapture(excludedBundleIDs: [])`, immediately calls
  `stop()`. macOS shows the TCC prompt
  (`kTCCServiceAudioCapture`). On grant, sub-task ✓.
  On deny, sub-task ✗ with: «Не разрешено. Открыть Настройки» →
  deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
  On window focus return, re-check permission silently; flip to ✓ if
  user granted in System Settings.

### Settings — "Excluded apps" section

Placed after the existing "Audio devices" group. Wording follows the
project's minimalist copy preference (per memory note).

Empty state shows a one-line hint. Non-empty state shows the list of
selected bundle IDs with app icons. Add via sheet picker; remove via
`×` button per row.

### Status pill and error states

The existing error pill machinery (`.error` state via `StatusDot.warn`
already exists for test mode) gains one new banner for Process-Tap
specific failures, surfaced when:

- The silent-frame watchdog fires (see Error handling)
- `AudioHardwareCreateProcessTap` returns a non-zero `OSStatus`

The banner copy includes a primary action — "Открыть Настройки" — that
opens the audio-capture privacy panel.

## Error handling

| Scenario | Detection | UX |
| -------- | --------- | -- |
| TCC denied silently — tap created OK but IOProc returns all-zero samples | Silent-frame watchdog: 10 s of continuous all-zero amplitude while session is `active` | Status pill → `.error`. Banner «Захват звука не разрешён в системе. Открыть настройки?» |
| `AudioHardwareCreateProcessTap` returns non-zero OSStatus | `peerCapture.start()` throws | Banner with four-CC error code. Logged to `unison.log`. |
| `AudioHardwareCreateAggregateDevice` fails | Same as above | Same as above |
| User changes excluded apps during active session | Settings observer | In-Settings banner «Изменения применятся при следующем запуске» — does not interrupt the active session |
| Default output device disconnects (e.g., AirPods turn off) | Existing AVAudioEngine routing — no new code | Mixer reroutes to new default automatically (existing macOS behavior) |

### Logging

The existing `unison.log` (under `~/Library/Logs/Unison/`) gains four
new lines per session:

```
[tap.start] excluded=[bundle1, bundle2, ourPID]
[tap.tcc]   kTCCServiceAudioCapture=granted | denied | notDetermined
[tap.warn]  all-zero amplitude for 5s   (rate-limited 1/min, only during active)
[tap.stop]  reason=user | error | deinit
```

Helps remote debugging when a user reports translation not working.

## Migration

Zero special migration code. Behavior on first launch of the new
version for an existing user:

- **Onboarding does not re-trigger.** The user already passed it; new
  Audio setup sub-tasks are not retroactively required.
- **BlackHole 16ch on the user's system is not touched.** Stays
  installed, just unused by Unison.
- **BlackHole 2ch is detected by the installer and skipped.** They
  already have it from the previous flow.
- **TCC audio capture is not granted yet** — they were never asked.
  On the user's first Start click, macOS shows the TCC prompt (because
  we call `AudioHardwareCreateProcessTap`); standard system UX.
  - Grant → translation works, transparent migration
  - Deny → silent-frame watchdog catches it within 10 s; banner shows
    «Открыть Настройки»
- **Excluded apps Settings** defaults to empty list on upgrade.

The result: users upgrading from BH 16ch see exactly one new dialog
(the TCC prompt) on first Start, and everything else stays the same
from their perspective.

## Testing

### Unit (Swift Testing, matching existing convention)

- `ProcessTapCapture` — excluded bundle IDs → PIDs resolution; verify
  `CATapDescription` is constructed with the right argument set
  (`monoGlobalTapButExcludeProcesses`, `mutedWhenTapped`, `isPrivate=true`)
- `AudioProcessRegistry.runningAudioProcesses()` — listing returns
  non-empty during a typical session; sort order; icon path resolution
- `Settings` — `excludedTapBundleIDs` Codable round-trip
- `OnboardingViewModel` — sub-task state machine: install ✓ + tcc ✓ → completed;
  install ✓ + tcc ✗ → step still pending; granting later flips to ✓
- Silent-frame watchdog — 10 s of zero amplitude in an active session
  flips state to `.error`; non-zero amplitude resets the timer

### Integration / manual

- Host smoke: complete onboarding on a clean macOS user, click Start,
  play test audio, verify transcript appears
- VM scenario: similar to existing `vm-screenshot.sh` flow, but with
  `UNISON_FORCE_STATE=onboarding-done` + a Developer-ID signed build
  (TCC will persist for signed bundles, ad-hoc will silently fail)
- Excluded-apps scenario: start translation with Spotify in the
  excluded list and Spotify actively playing music; verify the
  transcript only reflects the meeting source, not Spotify

### What's not covered by tests

- TCC denial → user goes to System Settings → grants → returns. The
  flow exists in code (on-window-focus re-check) but is hard to
  automate; covered by manual smoke.
- Process Tap behavior under Apple's CoreAudio updates (out of our
  control; relies on Apple's API stability)

## Open questions

These are deliberately small; resolved during plan writing or
implementation, not blockers for the spec:

- Exact UI copy for onboarding sub-tasks and Settings hint, per
  minimalist memo
- Whether the Excluded apps picker shows all CoreAudio process objects
  or only those currently producing audio. Default: all process
  objects (a paused music app should still be add-able to the
  exclusion list before it starts playing)
- Whether to remove the `PeerAudioCapture` protocol now that only one
  implementation remains — out of scope for this task, decided later
- Whether to include a "What's New" banner on first launch after
  upgrade explaining the change — out of scope, the TCC prompt is
  self-explanatory

## Success criteria

The spec is implemented successfully when:

1. A clean macOS user can complete onboarding, click Start in a
   browser-based meeting (Google Meet in Chrome) or a native meeting
   (Zoom), and see translated transcript without changing any audio
   routing settings in Zoom/Meet/Browser.
2. Existing users upgrading from the BH 16ch version see exactly one
   TCC prompt on first Start and translation works thereafter.
3. The user's "original volume" slider still controls the original
   meeting audio mix — at 0 they hear only translation, at 1 they
   hear both at full mix.
4. Adding Spotify to "Excluded apps" → starting translation → playing
   Spotify → Spotify continues to play normally (not muted, not
   translated).
5. Denying the TCC prompt produces a banner with a working deep link
   to System Settings, and granting permission there + clicking
   Start succeeds without restart.
6. `BlackHole 16ch` on the user's system is not removed; other apps
   can still use it.
