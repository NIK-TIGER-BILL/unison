# Transcript Recency Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render only recent transcript bubbles (≤ 30 s since last activity, last 4) and dissolve the rest, while keeping the full history in `TranscriptStore` for a future save-transcript feature.

**Architecture:** Windowing is a pure view-layer projection over the untouched `store.entries`: `recentEntries` (filter by a new `lastActivityAt`) → `group` (unchanged) → `capTail` (count cap). `TranscriptViewModel.visibleBubbleGroups(at:)` composes them; `TranscriptView` drives it from a 1 s `TimelineView` clock so bubbles expire during silence, reusing the existing 0.7 s removal transition for the dissolve.

**Tech Stack:** Swift 6, SwiftPM, SwiftUI (macOS 26), Swift Testing (`@Test`/`#expect`), `@Observable` view models.

**Spec:** `docs/superpowers/specs/2026-06-23-transcript-recency-window-design.md`

**Conventions for this codebase (read before starting):**
- Build: `swift build`. Test: `swift test --no-parallel`. Single test: `swift test --no-parallel --filter <testFuncName>`.
- Test framework is **Swift Testing**, not XCTest: `@Test func name() { #expect(...) }`. `@MainActor` on tests that touch `TranscriptStore`/`TranscriptViewModel`.
- In test files, build `Date`s with the `epochDate(_:)` helper (in `Tests/UnisonDomainTests/CodableHelpers.swift`) and use `FakeClock(now:)` (in `Tests/UnisonDomainTests/Mocks/FakeClock.swift`) for controllable time. `Date` `==`, `.addingTimeInterval`, `.timeIntervalSince` are visible transitively via `@testable import UnisonDomain` — no `import Foundation` needed (see `ClockTests.swift`).
- Module layout: `TranscriptEntry`/`TranscriptStore`/`Clock` live in **UnisonDomain**; `TranscriptGrouping`/`BubbleViewModel`/`BubbleGroup`/`TranscriptViewModel`/`TranscriptView` live in **UnisonUI**; `Composition` lives in **UnisonApp**. Tests live in `Tests/UnisonDomainTests` (which `@testable import` both UnisonDomain and UnisonUI).

---

### Task 1: Add `lastActivityAt` to `TranscriptEntry`

The recency window keys off *last activity*, not creation time, because a continuous monologue stays one entry (entry-id rotates only after a ≥ 5 s input gap) whose creation `timestamp` quickly goes stale. This task adds the field, defaulting to `timestamp` so every existing call site is unaffected.

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptEntry.swift`
- Test: `Tests/UnisonDomainTests/TranscriptEntryTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnisonDomainTests/TranscriptEntryTests.swift`:

```swift
@Test func transcriptEntry_lastActivityAt_defaultsToTimestamp() {
    let e = TranscriptEntry(
        id: freshUUID(), speaker: .me, originalText: nil, translatedText: "Hi",
        sourceLanguage: nil, targetLanguage: .en, timestamp: epochDate(42)
    )
    #expect(e.lastActivityAt == e.timestamp)
    #expect(e.lastActivityAt == epochDate(42))
}

@Test func transcriptEntry_lastActivityAt_explicitOverride() {
    let e = TranscriptEntry(
        id: freshUUID(), speaker: .me, originalText: nil, translatedText: "Hi",
        sourceLanguage: nil, targetLanguage: .en,
        timestamp: epochDate(42), lastActivityAt: epochDate(99)
    )
    #expect(e.lastActivityAt == epochDate(99))
    #expect(e.timestamp == epochDate(42))
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter transcriptEntry_lastActivityAt`
Expected: BUILD FAILURE — `value of type 'TranscriptEntry' has no member 'lastActivityAt'` and `extra argument 'lastActivityAt' in call`.

- [ ] **Step 3: Implement the field**

In `Sources/UnisonDomain/TranscriptEntry.swift`, add the stored property after `public let timestamp: Date`:

```swift
    public let timestamp: Date
    /// Time of the most recent delta folded into this entry. Defaults to
    /// `timestamp` (creation). Bumped by `TranscriptStore.apply`. Drives
    /// the transcript recency window so a long continuous utterance (one
    /// entry, many deltas) stays visible while still being spoken, and a
    /// finished one lingers for the window after its *last* delta.
    public var lastActivityAt: Date
```

Add the parameter to `init` (right after `timestamp: Date,`) and assign it:

```swift
    public init(
        id: UUID, speaker: Speaker,
        originalText: String? = nil, translatedText: String,
        sourceLanguage: Language?, targetLanguage: Language,
        timestamp: Date,
        lastActivityAt: Date? = nil,
        translationAtRisk: Bool = false
    ) {
        self.id = id
        self.speaker = speaker
        self.originalText = originalText
        self.translatedText = translatedText
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.lastActivityAt = lastActivityAt ?? timestamp
        self.translationAtRisk = translationAtRisk
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter transcriptEntry_lastActivityAt`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptEntry.swift Tests/UnisonDomainTests/TranscriptEntryTests.swift
git commit -m "feat(domain): add lastActivityAt to TranscriptEntry

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Stamp `lastActivityAt` from an injectable clock in `TranscriptStore`

`apply` currently stamps `Date()` for new entries and never touches activity time. Switch it to an injected `Clock` (matching the codebase's `Clock`/`SystemClock` convention) and bump `lastActivityAt` on every delta.

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptStore.swift`
- Test: `Tests/UnisonDomainTests/TranscriptStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnisonDomainTests/TranscriptStoreTests.swift`:

```swift
@Test @MainActor func transcriptStore_apply_stampsActivityFromClock() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    #expect(store.entries[0].timestamp == epochDate(1000))
    #expect(store.entries[0].lastActivityAt == epochDate(1000))
}

@Test @MainActor func transcriptStore_apply_bumpsLastActivityAtOnLaterDelta() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    clock.advance(by: 7)
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hi", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].lastActivityAt == epochDate(1007)) // bumped to latest delta
    #expect(store.entries[0].timestamp == epochDate(1000))      // creation unchanged
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter transcriptStore_apply`
Expected: BUILD FAILURE — `argument passed to call that takes no arguments` (the `clock:` initializer doesn't exist yet).

- [ ] **Step 3: Implement clock injection + activity bump**

In `Sources/UnisonDomain/TranscriptStore.swift`, replace `public init() {}` with a clock-injecting initializer and stored property:

```swift
    private let clock: Clock

    public init(clock: Clock = SystemClock()) {
        self.clock = clock
    }
```

In `apply(_:)`, inside the `if let idx = ...` branch, add an activity bump immediately after the `switch delta.kind { ... }` block (still inside the `if let`):

```swift
        if let idx = entries.firstIndex(where: { $0.id == delta.entryId }) {
            switch delta.kind {
            case .original:
                entries[idx].originalText = (entries[idx].originalText ?? "") + delta.text
            case .translated:
                entries[idx].translatedText += delta.text
                if !delta.text.isEmpty {
                    entries[idx].translationAtRisk = false
                }
            }
            entries[idx].lastActivityAt = clock.now()
        } else {
```

In the `else` branch (new entry), change `timestamp: Date()` to `timestamp: clock.now()` (the entry's `lastActivityAt` then defaults to the same instant):

```swift
            let entry = TranscriptEntry(
                id: delta.entryId,
                speaker: delta.speaker,
                originalText: delta.kind == .original ? delta.text : nil,
                translatedText: delta.kind == .translated ? delta.text : "",
                sourceLanguage: nil,
                targetLanguage: targetLang,
                timestamp: clock.now()
            )
            entries.append(entry)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter transcriptStore_apply`
Expected: PASS (these 2 tests plus the pre-existing `transcriptStore_apply...` ones, all green).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptStore.swift Tests/UnisonDomainTests/TranscriptStoreTests.swift
git commit -m "feat(domain): stamp TranscriptStore activity from injected clock

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `TranscriptGrouping.recentEntries` (time filter)

Pure filter keeping entries whose `lastActivityAt` is within the window of `now`. Runs *before* `group()` so the sentence-splitting regex only touches the recent slice.

**Files:**
- Modify: `Sources/UnisonUI/TranscriptGrouping.swift`
- Test: `Tests/UnisonDomainTests/TranscriptGroupingTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnisonDomainTests/TranscriptGroupingTests.swift`. (`makeEntry` already exists in this file; it sets `timestamp: epochDate(0)`, so `lastActivityAt` defaults to `epochDate(0)` — we override it per entry below.)

```swift
// MARK: - Recency window (recentEntries)

@Test func recentEntries_keepsWithinWindow_dropsOlder() {
    var fresh = makeEntry(.me, original: "new", translated: "новое")
    fresh.lastActivityAt = epochDate(100)
    var stale = makeEntry(.peer, original: "old", translated: "старое")
    stale.lastActivityAt = epochDate(50)
    let kept = TranscriptGrouping.recentEntries([stale, fresh], now: epochDate(120), within: 30)
    #expect(kept.count == 1)
    #expect(kept[0].id == fresh.id)
}

@Test func recentEntries_boundaryInclusive_atExactlyWithin() {
    var e = makeEntry(.me, original: "edge", translated: "край")
    e.lastActivityAt = epochDate(100)
    // now - lastActivityAt == exactly 30 → kept (<=)
    let kept = TranscriptGrouping.recentEntries([e], now: epochDate(130), within: 30)
    #expect(kept.count == 1)
}

@Test func recentEntries_empty_returnsEmpty() {
    let kept = TranscriptGrouping.recentEntries([], now: epochDate(0), within: 30)
    #expect(kept.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter recentEntries`
Expected: BUILD FAILURE — `type 'TranscriptGrouping' has no member 'recentEntries'`.

- [ ] **Step 3: Implement `recentEntries`**

In `Sources/UnisonUI/TranscriptGrouping.swift`, add inside `enum TranscriptGrouping`, immediately after the `group(...)` method (before `// MARK: - Private`):

```swift
    /// Entries whose most-recent activity (`lastActivityAt`) is within
    /// `within` seconds of `now`. The transcript recency window's time
    /// filter — keys off activity, not creation, so a long continuous
    /// utterance (one entry, many deltas) stays visible while still
    /// being spoken. Pure; inject `now` in tests.
    static func recentEntries(
        _ entries: [TranscriptEntry],
        now: Date,
        within: TimeInterval
    ) -> [TranscriptEntry] {
        entries.filter { now.timeIntervalSince($0.lastActivityAt) <= within }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter recentEntries`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/TranscriptGrouping.swift Tests/UnisonDomainTests/TranscriptGroupingTests.swift
git commit -m "feat(ui): add TranscriptGrouping.recentEntries time filter

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `TranscriptGrouping.capTail` (count cap + re-flag)

Keep the last `max` bubbles across all groups, re-assembling survivors into speaker-run groups and re-deriving `isFirstInGroup`/`isLastInGroup` (so a truncated group's new topmost bubble renders a proper rounded top, not a "continued" corner). `isLive`/`translationLost`/`speaker`/ids preserved. No-op when total ≤ `max`.

**Files:**
- Modify: `Sources/UnisonUI/TranscriptGrouping.swift`
- Test: `Tests/UnisonDomainTests/TranscriptGroupingTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnisonDomainTests/TranscriptGroupingTests.swift`:

```swift
// MARK: - Count cap (capTail)

@Test func capTail_trimsSameSpeakerRunToLastN() {
    let entries = (0..<5).map { i in makeEntry(.me, original: "m\(i)", translated: "t\(i)") }
    let groups = TranscriptGrouping.group(entries: entries)
    #expect(groups.count == 1)          // same speaker → one group
    #expect(groups[0].bubbles.count == 5)

    let capped = TranscriptGrouping.capTail(groups, max: 4)
    #expect(capped.count == 1)
    #expect(capped[0].bubbles.count == 4)
    #expect(capped[0].bubbles.first?.primaryText == "m1")   // m0 dropped
    #expect(capped[0].bubbles.first?.isFirstInGroup == true)
    #expect(capped[0].bubbles.last?.primaryText == "m4")
    #expect(capped[0].bubbles.last?.isLastInGroup == true)
}

@Test func capTail_noOpWhenWithinLimit() {
    let entries = [makeEntry(.me, original: "a", translated: "x"),
                   makeEntry(.peer, original: "b", translated: "y")]
    let groups = TranscriptGrouping.group(entries: entries)
    let capped = TranscriptGrouping.capTail(groups, max: 4)
    #expect(capped.count == groups.count)
    #expect(capped.flatMap { $0.bubbles }.count == 2)
}

@Test func capTail_reflagsFirstWhenCutLandsMidGroup() {
    let me = makeEntry(.me, original: "hi", translated: "привет")
    let longText = String(repeating: "Предложение раз. ", count: 30) // > 240 chars → splits
    let peer = makeEntry(.peer, original: "x", translated: longText)
    let groups = TranscriptGrouping.group(entries: [me, peer], splitThreshold: 240)
    #expect(groups.flatMap { $0.bubbles }.count >= 3) // me + ≥2 peer chunks

    let capped = TranscriptGrouping.capTail(groups, max: 1)
    #expect(capped.count == 1)
    #expect(capped[0].speaker == .peer)
    #expect(capped[0].bubbles.count == 1)
    #expect(capped[0].bubbles[0].isFirstInGroup == true)  // was a continuation, now first
    #expect(capped[0].bubbles[0].isLastInGroup == true)
}

@Test func capTail_preservesLiveFlagOnLastBubble() {
    let me = makeEntry(.me, original: "a", translated: "x")
    let peerLive = makeEntry(.peer, original: "b", translated: "y")
    let groups = TranscriptGrouping.group(entries: [me, peerLive], liveEntryId: peerLive.id)
    #expect(groups.last?.bubbles.last?.isLive == true)
    let capped = TranscriptGrouping.capTail(groups, max: 1)
    #expect(capped.last?.bubbles.last?.isLive == true)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter capTail`
Expected: BUILD FAILURE — `type 'TranscriptGrouping' has no member 'capTail'`.

- [ ] **Step 3: Implement `capTail`**

In `Sources/UnisonUI/TranscriptGrouping.swift`, add immediately after `recentEntries` (still before `// MARK: - Private`):

```swift
    /// Keep only the last `max` bubbles across all groups (the recency
    /// count-cap), re-assembling survivors into speaker-run groups and
    /// re-deriving `isFirstInGroup` / `isLastInGroup`. `isLive`,
    /// `translationLost`, `speaker` and bubble ids are preserved. When
    /// the total bubble count is already ≤ `max`, the input is returned
    /// unchanged (existing flags intact). Pure.
    static func capTail(_ groups: [BubbleGroup], max: Int) -> [BubbleGroup] {
        guard max > 0 else { return [] }
        let flat = groups.flatMap { $0.bubbles }
        guard flat.count > max else { return groups }
        let kept = Array(flat.suffix(max))

        var result: [BubbleGroup] = []
        var run: [BubbleViewModel] = []

        func flush() {
            guard let head = run.first else { return }
            let lastIdx = run.count - 1
            let flagged = run.enumerated().map { i, b in
                BubbleViewModel(
                    id: b.id,
                    speaker: b.speaker,
                    primaryText: b.primaryText,
                    secondaryText: b.secondaryText,
                    isFirstInGroup: i == 0,
                    isLastInGroup: i == lastIdx,
                    isLive: b.isLive,
                    translationLost: b.translationLost
                )
            }
            result.append(BubbleGroup(id: head.id, speaker: head.speaker, bubbles: flagged))
            run = []
        }

        for b in kept {
            if let last = run.last, last.speaker != b.speaker {
                flush()
            }
            run.append(b)
        }
        flush()
        return result
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter capTail`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/TranscriptGrouping.swift Tests/UnisonDomainTests/TranscriptGroupingTests.swift
git commit -m "feat(ui): add TranscriptGrouping.capTail count cap

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `TranscriptViewModel.visibleBubbleGroups(at:)`

Compose the window: `recentEntries` → `group` → `capTail`, gated by `windowingEnabled`. Keep the existing `bubbleGroups` property (now delegating at `nowProvider()`) so current callers/tests are unaffected.

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptViewModelTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/UnisonDomainTests/TranscriptViewModelTests.swift`. (The private `appendMe`/`appendPeer` helpers and `FakeClock`/`epochDate` are available in this file.)

```swift
// MARK: - Recency window (visibleBubbleGroups)

@MainActor
@Test func transcriptVM_window_dropsEntriesOlderThanWindow() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    _ = appendMe(store, "старое", "old")        // lastActivityAt = 1000
    clock.advance(by: 100)                        // t = 1100
    _ = appendPeer(store, "new", "новое")        // lastActivityAt = 1100
    let groups = vm.visibleBubbleGroups(at: clock.now())  // now = 1100
    #expect(groups.count == 1)
    #expect(groups[0].speaker == .peer)
}

@MainActor
@Test func transcriptVM_window_emptyAfterSilence() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    _ = appendMe(store, "a", "x")
    let groups = vm.visibleBubbleGroups(at: epochDate(1031)) // 31 s later, silence
    #expect(groups.isEmpty)
}

@MainActor
@Test func transcriptVM_window_capsToMaxVisibleBubbles() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    for i in 0..<6 { _ = appendMe(store, "m\(i)", "t\(i)") } // one me-run → 6 bubbles
    let groups = vm.visibleBubbleGroups(at: clock.now())
    #expect(groups.flatMap { $0.bubbles }.count == TranscriptViewModel.maxVisibleBubbles)
}

@MainActor
@Test func transcriptVM_windowingDisabled_showsEverything() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    vm.windowingEnabled = false
    for i in 0..<6 { _ = appendMe(store, "m\(i)", "t\(i)") }
    let groups = vm.visibleBubbleGroups(at: epochDate(99_999)) // far future, silence
    #expect(groups.flatMap { $0.bubbles }.count == 6)
}

@MainActor
@Test func transcriptVM_bubbleGroups_usesNowProvider() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let vm = TranscriptViewModel(store: store)
    vm.nowProvider = { clock.now() }
    _ = appendMe(store, "старое", "old")
    clock.advance(by: 100)
    _ = appendPeer(store, "new", "новое")
    #expect(vm.bubbleGroups.count == 1)          // windowed via nowProvider
    #expect(vm.bubbleGroups[0].speaker == .peer)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --no-parallel --filter transcriptVM_window`
Expected: BUILD FAILURE — `value of type 'TranscriptViewModel' has no member 'visibleBubbleGroups'` / `... 'windowingEnabled'` / `... 'maxVisibleBubbles'`.

- [ ] **Step 3: Implement the windowing API**

In `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift`, add the constants next to `liveFinalizeDelaySeconds` (after that declaration):

```swift
    /// Recency window: a bubble is visible only if its source entry's
    /// last activity was within this many seconds of "now". Older
    /// bubbles dissolve; after this long of silence the transcript is
    /// empty.
    public static let windowSeconds: TimeInterval = 30

    /// Hard cap on how many bubbles are visible at once, even within the
    /// time window. Counts individual bubbles — a long split message can
    /// crowd out older ones.
    public static let maxVisibleBubbles: Int = 4

    /// When `false`, the recency window is bypassed and the full
    /// transcript renders (legacy behaviour). `seedTranscriptDemo` sets
    /// this `false` so the screenshot harness shows all seeded bubbles
    /// and doesn't empty out `windowSeconds` after launch.
    public var windowingEnabled: Bool = true
```

Replace the existing `bubbleGroups` computed property:

```swift
    public var bubbleGroups: [BubbleGroup] {
        TranscriptGrouping.group(
            entries: store.entries,
            liveEntryId: activeLiveEntryId
        )
    }
```

with the delegating property plus the windowing function:

```swift
    public var bubbleGroups: [BubbleGroup] {
        visibleBubbleGroups(at: nowProvider())
    }

    /// The windowed slice of bubble groups at the given instant. A pure
    /// projection over the full `store.entries` — the store is never
    /// mutated, so the complete history stays available for export/save.
    /// The view passes a `TimelineView` clock so bubbles expire on
    /// schedule during silence, not only when new content arrives.
    public func visibleBubbleGroups(at now: Date) -> [BubbleGroup] {
        guard windowingEnabled else {
            return TranscriptGrouping.group(
                entries: store.entries,
                liveEntryId: activeLiveEntryId
            )
        }
        let recent = TranscriptGrouping.recentEntries(
            store.entries,
            now: now,
            within: Self.windowSeconds
        )
        let groups = TranscriptGrouping.group(
            entries: recent,
            liveEntryId: activeLiveEntryId
        )
        return TranscriptGrouping.capTail(groups, max: Self.maxVisibleBubbles)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --no-parallel --filter transcriptVM`
Expected: PASS — the 6 new window tests plus the pre-existing `transcriptVM_*` tests (e.g. `transcriptVM_bubbleGroups_reflectsStoreEntries`) all green.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI/ViewModels/TranscriptViewModel.swift Tests/UnisonDomainTests/TranscriptViewModelTests.swift
git commit -m "feat(ui): add TranscriptViewModel recency-window projection

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Drive the window from a `TimelineView` in `TranscriptView`

So bubbles expire during silence (not only on new content), and the change animates via the existing removal transition.

**Files:**
- Modify: `Sources/UnisonUI/Views/TranscriptView.swift`
- Verify: `swift build` + existing smoke snapshot tests (no new unit test — this is a SwiftUI view; the transparent transcript window's snapshots are smoke-only by design).

- [ ] **Step 1: Replace the `bubbles` computed property**

In `Sources/UnisonUI/Views/TranscriptView.swift`, replace:

```swift
    private var bubbles: some View {
        BubbleGroupView(
            groups: vm.bubbleGroups,
            scale: vm.bubbleScale,
            isTestMode: vm.isTestMode
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

with:

```swift
    private var bubbles: some View {
        // 1 s tick so the recency window re-evaluates during silence —
        // bubbles cross the 30 s boundary and dissolve on the clock, not
        // only when new content arrives. The dissolve itself is the
        // existing removal transition in `BubbleGroupView`; the
        // `.animation(value:)` just opens an animated transaction when
        // the visible set changes.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let groups = vm.visibleBubbleGroups(at: context.date)
            BubbleGroupView(
                groups: groups,
                scale: vm.bubbleScale,
                isTestMode: vm.isTestMode
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(.default, value: groups.flatMap { $0.bubbles.map(\.id) })
        }
    }
```

- [ ] **Step 2: Build and run the transcript snapshot smoke tests**

Run: `swift build && swift test --no-parallel --filter transcript`
Expected: PASS — build succeeds; `TranscriptViewSnapshotTests` (e.g. `transcript_empty`, `transcript_oneMeBubble`, `transcript_multiGroup`) and the domain `transcript*` tests are all green.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonUI/Views/TranscriptView.swift
git commit -m "feat(ui): drive transcript recency window from a TimelineView tick

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Disable windowing for the screenshot demo

The 6 seeded demo replies are stamped at launch; with windowing on they'd trim to 4 and empty out 30 s after boot, breaking the Tart/README screenshot harness. Disable windowing for the demo seed.

**Files:**
- Modify: `Sources/UnisonApp/Composition.swift`
- Verify: `swift build`.

- [ ] **Step 1: Set `windowingEnabled = false` in the demo seed**

In `Sources/UnisonApp/Composition.swift`, in `seedTranscriptDemo`, replace:

```swift
        // Pin the elapsed-time pill at a recognisable value so the
        // screenshot is reproducible across captures.
        viewModel.previewElapsedSeconds = 47
    }
```

with:

```swift
        // Pin the elapsed-time pill at a recognisable value so the
        // screenshot is reproducible across captures.
        viewModel.previewElapsedSeconds = 47
        // The recency window would trim these 6 seeded replies to the
        // last 4 and empty the transcript 30 s after launch (their
        // timestamps are fixed at seed time, and the screenshot harness
        // captures at an arbitrary post-launch moment). Show the full
        // seeded conversation deterministically instead.
        viewModel.windowingEnabled = false
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS — builds cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonApp/Composition.swift
git commit -m "fix(app): keep full demo transcript by disabling windowing in seed

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Full-suite verification + manual smoke

**Files:** none (verification only).

- [ ] **Step 1: Run the whole test suite**

Run: `swift test --no-parallel`
Expected: PASS — entire suite green (no regressions in TranscriptStore/Grouping/ViewModel/snapshot tests).

- [ ] **Step 2: Manual smoke of the demo (optional but recommended)**

Run the app with the demo force-state and confirm the transcript shows the full seeded conversation and does NOT empty after 30 s (windowing disabled for the demo):

Run: `UNISON_FORCE_STATE=transcript-demo swift run` (or the project's normal run path — see the `run` skill / README "swift build").
Expected: transcript window shows all 6 seeded replies, stable over time.

- [ ] **Step 3: Manual smoke of the live window (optional)**

In a real translation session, confirm: only the last ≤ 4 recent bubbles show; older ones fade out (0.7 s dissolve); after ~30 s of silence the transcript is empty; a long continuous utterance stays visible while being spoken. If Reduce Motion is on, bubbles disappear without the dissolve (expected — handled by the existing transition).

- [ ] **Step 4: Confirm history is retained (memory requirement)**

Sanity check (can be a scratch test or lldb/print): after bubbles have dissolved from view, `store.entries` still contains every entry. This is guaranteed by construction (windowing never mutates the store) and covered indirectly by `transcriptVM_windowingDisabled_showsEverything`, but is the core requirement, so verify it once.

---

## Self-Review

**Spec coverage:**
- Time window (≤ 30 s since last activity) → Task 3 (`recentEntries`) + Task 5 (`windowSeconds`).
- Count cap (last 4 individual bubbles) → Task 4 (`capTail`) + Task 5 (`maxVisibleBubbles`).
- Empty after silence → Task 5 test `transcriptVM_window_emptyAfterSilence`.
- Dissolve animation → Task 6 (TimelineView + reuse of existing removal transition); Reduce Motion handled by existing `bubbleTransition` (Task 8 step 3 verifies).
- History stays in memory → guaranteed by view-layer-only projection (Tasks 3–5 never mutate `store`); Task 8 step 4.
- `lastActivityAt` (long-monologue correctness) → Task 1 (field) + Task 2 (bump on each delta).
- Demo/screenshot stability → Task 7 (`windowingEnabled = false`).
- Constants tunable → Task 5 (`windowSeconds`, `maxVisibleBubbles` statics).

**Placeholder scan:** none — every code/test step contains complete code; every run step has an exact command and expected result.

**Type consistency:** `recentEntries(_:now:within:) -> [TranscriptEntry]`, `capTail(_:max:) -> [BubbleGroup]`, `visibleBubbleGroups(at:) -> [BubbleGroup]`, `TranscriptStore(clock:)`, `TranscriptEntry(..., lastActivityAt:)`, `windowingEnabled`/`windowSeconds`/`maxVisibleBubbles` — names match across all tasks and the spec. `BubbleViewModel` init parameters used in `capTail` match its real signature (`id, speaker, primaryText, secondaryText, isFirstInGroup, isLastInGroup, isLive, translationLost`).
