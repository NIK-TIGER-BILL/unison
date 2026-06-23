# Transcript Recency Window — design

**Date:** 2026-06-23
**Status:** Approved, ready for implementation plan

## Background

The floating transcript window renders **every** bubble derived from
`TranscriptStore.entries`. Over a long call the list grows without bound,
the older content scrolls off only via `.defaultScrollAnchor(.bottom)`, and
the overlay accumulates visual weight on top of the user's video call.

We want the transcript to read as a **live, ephemeral caption strip**: only
recent speech is visible, the rest dissolves away — while the full history
stays in memory untouched, so a future "save meeting transcript" feature can
serialise everything. That persistence feature is **not** built here; we only
make sure the data is never discarded.

The original design mock (`design/transcript-final/index.html`) already
envisioned this: a `prune()` function with `VISIBLE_LIMIT = 3` that adds a
`fade-out` (0.7 s dissolve) to the oldest groups. But the JS version
**removed the bubbles from the DOM** — i.e. deleted the data — and that
pruning logic was never ported to Swift. This spec ports the *visual*
behaviour without the data loss.

### Why entry **creation** time cannot be the recency clock

`currentEntryId` in `OpenAIRealtimeStream` rotates only after a **≥ 5 s input
gap** (`turnGapSeconds`, `rotateOnInputGap`). A continuous monologue therefore
stays a **single** `TranscriptEntry` that keeps accumulating deltas for 40 s+.
`TranscriptEntry.timestamp` is stamped once, at entry creation. Filtering by
`timestamp` would hide a long utterance **mid-speech** (created > 30 s ago),
and then make it vanish the instant the speaker pauses. The window must key off
**last activity**, not creation. See "Domain change" below.

## Goal

Show only the bubbles that satisfy **both**:

1. **Time:** the source entry's last activity was ≤ `windowSeconds` (30 s) ago.
2. **Count:** at most the last `maxVisibleBubbles` (4) bubbles among those that
   pass the time filter.

Bubbles leaving the visible set **dissolve** via the existing 0.7 s removal
transition. After > 30 s of silence the visible set is empty and the transcript
is blank. The count is measured in **individual bubbles** (a long message split
across several bubbles can crowd out everything else — accepted).

`TranscriptStore.entries` is **never** filtered or mutated by this feature.
Windowing is purely a view-layer projection. `exportAsText()` and any future
save path see the complete history.

## Non-goals

- **Saving / persisting meeting transcripts.** Out of scope; this spec only
  guarantees the data survives in memory so that feature is unblocked later.
- **User-configurable window size.** `windowSeconds` and `maxVisibleBubbles`
  are code constants, not Settings UI. YAGNI until asked.
- **Contiguity guarantees across re-activated old entries.** A late delta to an
  old entry (rare; only the at-risk / reconnect path appends late translated
  text) can re-surface that entry while a newer-positioned one stays expired.
  This is acceptable and intuitive ("it just got updated"); we do not add
  special handling.

## Approach

**View-layer windowing via pure functions + a periodic tick.** Chosen over:

- **Port `prune()` to the store** (delete old entries): rejected — violates the
  hard requirement that data stays in memory for future save.
- **Keep all bubbles mounted, ramp opacity by age**: rejected — the view tree
  grows unbounded over a call, a zero-opacity bubble still occupies layout, and
  "empty after 30 s" still needs removal. We borrow only its spirit: the oldest
  *visible* bubble already softens under `.scrollEdgeEffectStyle(.soft)`.

The store stays the full source of truth. A pure projection
(`recentEntries` → `group` → `capTail`) produces the visible slice. The view
re-evaluates that slice on a 1 s `TimelineView` tick so bubbles expire on the
clock during silence, not only when new content arrives.

## Domain change: `lastActivityAt`

`TranscriptEntry` gains:

```swift
public var lastActivityAt: Date   // defaults to `timestamp` in init
```

- `timestamp` stays = entry **creation** (used for ordering and the future save).
- `lastActivityAt` = time of the **most recent delta** folded into the entry.

`TranscriptStore.apply(_:)` bumps `entries[idx].lastActivityAt = now()` on every
delta (both `.original` and `.translated`, existing and freshly-minted entries).
A test clock seam (`var now: () -> Date = Date.init`) is added to `TranscriptStore`
so unit tests are deterministic; production uses the default.

This correctly:
- keeps a long live utterance visible while it is being spoken (recent delta),
- lets a finished utterance linger for `windowSeconds` after its **last** delta.

## Windowing functions (pure, in `TranscriptGrouping`)

`group(entries:splitThreshold:liveEntryId:)` is **unchanged**.

```swift
// Suffix of entries whose lastActivityAt is within `within` of `now`.
static func recentEntries(_ entries: [TranscriptEntry],
                          now: Date,
                          within: TimeInterval) -> [TranscriptEntry]

// Flatten groups → ordered bubbles, keep the last `max`, re-assemble into
// speaker-run groups, re-deriving isFirstInGroup / isLastInGroup. Preserves
// isLive, translationLost, speaker. Group id = first surviving bubble's id.
static func capTail(_ groups: [BubbleGroup], max: Int) -> [BubbleGroup]
```

`recentEntries` uses a straightforward `filter` on `lastActivityAt`
(O(n) per tick is negligible at realistic meeting sizes; could become a
suffix-walk later since arrival order is monotonic). Crucially it runs
**before** `group()`, so the sentence-splitting regex only processes the recent
slice, never the whole history.

`capTail` re-flagging matters because dropping the leading bubbles of a group
would otherwise leave a "continued" bubble (small top corner) as the topmost
visible one. After truncation the new first bubble of each surviving run gets
`isFirstInGroup = true`, the last gets `isLastInGroup = true`. `isLive` is
preserved as set by `group()` — only the global last bubble can be live and it
is always retained by `suffix`.

Edge: a non-contiguous survivor set (a dropped middle entry of a different
speaker) can merge two same-speaker runs into one group. Harmless visually and
extremely rare; not special-cased.

## View-model changes (`TranscriptViewModel`)

```swift
public static let windowSeconds: TimeInterval = 30
public static let maxVisibleBubbles: Int = 4
public var windowingEnabled: Bool = true        // demo sets false

func visibleBubbleGroups(at now: Date) -> [BubbleGroup]
```

`visibleBubbleGroups(at:)`:
- if `windowingEnabled == false` → `TranscriptGrouping.group(entries: store.entries, liveEntryId:)` (current full behaviour, unchanged),
- else → `capTail(group(recentEntries(store.entries, now, windowSeconds)), max: maxVisibleBubbles)`.

The existing `var bubbleGroups: [BubbleGroup]` is kept as
`visibleBubbleGroups(at: nowProvider())` so current callers and tests that read
the property at "now" keep working. The view uses the explicit `at:` form so it
can pass the `TimelineView` clock.

## View changes (`TranscriptView`)

Wrap the bubble list in a periodic tick and animate the visible-set changes so
expiry dissolves rather than pops:

```swift
TimelineView(.periodic(from: .now, by: 1)) { ctx in
    let groups = vm.visibleBubbleGroups(at: ctx.date)
    BubbleGroupView(groups: groups, scale: vm.bubbleScale, isTestMode: vm.isTestMode)
        .animation(.default, value: groups.flatMap { $0.bubbles.map(\.id) })
}
```

- The **dissolve timing** lives in the *existing*
  `BubbleGroupView.bubbleTransition` removal
  (`.opacity.animation(.easeOut(duration: 0.7))`), which overrides the ambient
  animation. The outer `.animation(_:value:)` exists only to open an animated
  transaction when the rendered set changes — keyed on the ordered list of
  visible bubble ids (cheap each tick) — so the transition fires on the clock,
  not only on new content. Any non-nil ambient animation works; `.default` is
  fine since the transition carries the real curve.
- The **top edge** softening from `.scrollEdgeEffectStyle(.soft)` already
  partially fades the oldest visible bubble — complementary, no new code.
- **Reduce Motion** is already honoured inside `bubbleTransition` (returns
  `.identity`), so the slice changes instantly without a dissolve. No
  accessibility change needed here.

## Demo / screenshot compatibility (`Composition.swift`)

`seedTranscriptDemo` sets `viewModel.windowingEnabled = false`. Rationale: the
6 seeded entries are stamped at launch, so with windowing on they would (a)
trim to the last 4 and (b) **empty out 30 s after boot** — breaking the Tart
screenshot harness and README captures, which may capture at any time after
launch. Disabling windowing keeps the demo deterministic and showing all 6
replies. The real app uses the default (`true`).

## Edge cases

- **Live bubble** is always newest → always within window and count → never hidden.
- **Long monologue** (one entry, many chunks): alive while spoken
  (`lastActivityAt` fresh); count-cap shows its last 4 chunks.
- **`isHidden`**: bubbles aren't rendered anyway; on un-hide the slice
  recomputes at the current time.
- **Performance:** `recentEntries` is a cheap compare; `group()` runs only on
  the recent slice; 1 s tick is trivial. History grows in memory by design.

## Testing

Pure functions make this mostly unit-testable without timers:

- `recentEntries`: in/out of the 30 s window by injected `now`; boundary at exactly 30 s.
- `capTail`: trims to last N bubbles; re-flags `isFirstInGroup`/`isLastInGroup`
  on truncated groups; preserves `isLive` and `translationLost`; merges/splits
  speaker runs correctly.
- `TranscriptStore.apply`: bumps `lastActivityAt` on each delta (inject the clock).
- `TranscriptViewModel.visibleBubbleGroups(at:)`: combined window + cap;
  `windowingEnabled == false` returns full groups; silence → empty.
- Existing `bubbleGroups` tests stay green (seed "now", ≤ 4 bubbles).

Snapshot tests are smoke-only for the transparent transcript window (no pixel
assert), so they don't break on bubble count; they still verify the view builds.

## Tunable constants

| Name | Value | Meaning |
|---|---|---|
| `windowSeconds` | 30 s | Max age (since last activity) of a visible bubble. |
| `maxVisibleBubbles` | 4 | Max bubbles shown among those within the window. |

Both are one-line changes.
