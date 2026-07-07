# Transcript Pairing Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the turn/FIFO transcript pairing with a sentence + pause-anchored model that pairs whole speech segments (source↔translation) so nothing drifts, driven by what Gemini actually emits.

**Architecture:** A pure `SentenceSegmenter` (NLTokenizer, language-aware) feeds a stateful `TranscriptModel` that accumulates each speaker's source & translation deltas, seals a "segment" into bubbles on the first of {clean sentence boundary with matching counts, max length, pause, translation-lag}, and **resets alignment at every pause** so a bad segment can't propagate. The UI reuses the commit-and-freeze bubble rendering.

**Tech Stack:** Swift 5, Swift Testing (`import Testing`, `@Test`), `NaturalLanguage.NLTokenizer`, SwiftPM. Run tests with `scripts/test.sh --filter <name>`; lint `scripts/lint.sh swiftlint`; build `swift build`.

**Spec:** `docs/superpowers/specs/2026-07-07-transcript-pairing-redesign-design.md`

---

## File structure

- Create `Sources/UnisonDomain/SentenceSegmenter.swift` — pure sentence split (NLTokenizer + abbreviation guard). One responsibility: text→(complete sentences, trailing).
- Create `Sources/UnisonDomain/TranscriptModel.swift` — the new source of truth. Holds `TranscriptBubble` + the segment/commit engine. Replaces `TranscriptStore`.
- Modify `Sources/UnisonDomain/TranscriptEntry.swift` — add `language` to `TranscriptDelta` (source/target language of the chunk).
- Modify `Sources/UnisonTranslation/GeminiEvents.swift` — `inputTranscript`/`outputTranscript` carry the frame `languageCode`.
- Modify `Sources/UnisonTranslation/GeminiLiveTranslateStream.swift` — emit raw deltas with language; delete the two-track FIFO.
- Modify `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift` — read `TranscriptModel`, map bubbles to `DisplayBubble`.
- Modify `Sources/UnisonApp/Composition.swift` — construct `TranscriptModel`, wire delta ingestion + a periodic `tick`.
- Delete (final task) `Sources/UnisonDomain/TranscriptStore.swift`, `Sources/UnisonUI/TranscriptGrouping.swift` (keep `groupDisplayBubbles` by moving it), their tests.
- Tests: `Tests/UnisonDomainTests/SentenceSegmenterTests.swift`, `Tests/UnisonDomainTests/TranscriptModelTests.swift`.

**Shared test helpers** already exist: `freshUUID()`, `epochDate(_:)`, `FakeClock`.

**Key types (defined across tasks, referenced here for consistency):**

```swift
// TranscriptBubble — one rendered unit produced by TranscriptModel.
public struct TranscriptBubble: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let source: String        // speaker's own words (original)
    public let translation: String
    public let translationLost: Bool
    public let committedAt: Date      // when it froze (or last activity while live)
    public let isLive: Bool
}
```

---

## Phase 1 — SentenceSegmenter (pure foundation)

### Task 1: SentenceSegmenter — split into complete sentences + trailing

**Files:**
- Create: `Sources/UnisonDomain/SentenceSegmenter.swift`
- Test: `Tests/UnisonDomainTests/SentenceSegmenterTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UnisonDomain

@Test func segmenter_twoSentences_plusTrailing() {
    let r = SentenceSegmenter.segment("Hi there. How are you? And then", language: .en)
    #expect(r.complete == ["Hi there.", "How are you?"])
    #expect(r.trailing == "And then")
}

@Test func segmenter_noTerminator_allTrailing() {
    let r = SentenceSegmenter.segment("still going on", language: .en)
    #expect(r.complete.isEmpty)
    #expect(r.trailing == "still going on")
}

@Test func segmenter_empty() {
    let r = SentenceSegmenter.segment("   ", language: .en)
    #expect(r.complete.isEmpty)
    #expect(r.trailing == "")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `scripts/test.sh --filter "segmenter_"`
Expected: FAIL — `SentenceSegmenter` not defined.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation
import NaturalLanguage

/// Splits streaming transcript text into fully-completed sentences plus the
/// trailing (still-forming) fragment, using Apple's language-aware sentence
/// tokenizer. `complete` are safe to freeze; `trailing` stays live.
public enum SentenceSegmenter {
    public static func segment(
        _ text: String, language: Language
    ) -> (complete: [String], trailing: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], "") }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.setLanguage(nlLanguage(for: language))
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            return true
        }
        guard let last = sentences.last else { return ([], "") }
        // The tokenizer always emits the trailing fragment as its own token;
        // if that token doesn't end with a terminator it's the live trailing.
        if endsWithTerminator(last) {
            return (sentences, "")
        }
        return (Array(sentences.dropLast()), last)
    }

    private static func endsWithTerminator(_ s: String) -> Bool {
        let terminators: Set<Character> = [".", "!", "?", "…", "。", "？", "！", "।"]
        let closers: Set<Character> = ["\"", "'", ")", "]", "}", "»", "”", "’"]
        var t = Substring(s)
        while let c = t.last, c.isWhitespace || closers.contains(c) { t = t.dropLast() }
        guard let c = t.last else { return false }
        return terminators.contains(c)
    }

    private static func nlLanguage(for language: Language) -> NLLanguage {
        switch language {
        case .ru: return .russian
        case .en: return .english
        case .es: return .spanish
        case .fr: return .french
        case .de: return .german
        case .it: return .italian
        case .pt: return .portuguese
        case .zh: return .simplifiedChinese
        case .ja: return .japanese
        case .ko: return .korean
        case .hi: return .hindi
        case .id: return .indonesian
        case .vi: return .vietnamese
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `scripts/test.sh --filter "segmenter_"`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/SentenceSegmenter.swift Tests/UnisonDomainTests/SentenceSegmenterTests.swift
git commit -m "SentenceSegmenter: NLTokenizer-based complete/trailing split"
```

### Task 2: SentenceSegmenter — abbreviations, multi-language, CJK, danda

**Files:**
- Modify: `Sources/UnisonDomain/SentenceSegmenter.swift`
- Test: `Tests/UnisonDomainTests/SentenceSegmenterTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func segmenter_abbreviations_notSplit() {
    // NLTokenizer handles most; the guard fixes the ones it misses (ru стр., pt Sr.).
    #expect(SentenceSegmenter.segment("Мы поддерживаем Telegram и т.д. Это удобно.", language: .ru).complete
            == ["Мы поддерживаем Telegram и т.д.", "Это удобно."])
    #expect(SentenceSegmenter.segment("Замулдинов Н.В. пришёл. Всё хорошо.", language: .ru).complete
            == ["Замулдинов Н.В. пришёл.", "Всё хорошо."])
    #expect(SentenceSegmenter.segment("См. стр. 5 внимательно. Там всё.", language: .ru).complete
            == ["См. стр. 5 внимательно.", "Там всё."])
    #expect(SentenceSegmenter.segment("O Sr. Silva chegou. Tudo bem.", language: .pt).complete
            == ["O Sr. Silva chegou.", "Tudo bem."])
}

@Test func segmenter_cjk_and_danda() {
    #expect(SentenceSegmenter.segment("今天天气很好。我们去公园吧。", language: .zh).complete
            == ["今天天气很好。", "我们去公园吧。"])
    #expect(SentenceSegmenter.segment("मैं ठीक हूँ। आप कैसे हैं।", language: .hi).complete
            == ["मैं ठीक हूँ।", "आप कैसे हैं।"])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "segmenter_abbreviations_notSplit"`
Expected: FAIL — "См. стр. 5..." and "O Sr. Silva..." split at the abbreviation (extra sentences). (CJK/danda already pass — they validate the language mapping.)

- [ ] **Step 3: Implement the abbreviation guard**

Add to `SentenceSegmenter`, and apply it by merging a sentence into the next when it ends with a known abbreviation:

```swift
    /// Lowercased abbreviation stems (without the trailing dot) that end in a
    /// period but do NOT end a sentence. NLTokenizer misses a few of these.
    private static func abbreviations(for language: Language) -> Set<String> {
        switch language {
        case .ru: return ["стр", "см", "рис", "табл", "гл", "т", "тд", "тп", "тк", "др", "г", "ул", "д", "пр", "им"]
        case .pt: return ["sr", "sra", "dr", "dra", "av", "pág"]
        case .es: return ["sr", "sra", "dr", "dra", "pág", "núm"]
        case .en: return ["mr", "mrs", "ms", "dr", "st", "vs", "etc", "no", "fig", "pp"]
        case .de: return ["hr", "fr", "dr", "nr", "bzw", "usw", "ca", "abb"]
        default: return []
        }
    }

    /// The last dotted token of `s` (letters right before a trailing period),
    /// lowercased, or nil.
    private static func trailingDottedToken(_ s: String) -> String? {
        var t = Substring(s)
        while let c = t.last, c.isWhitespace { t = t.dropLast() }
        guard t.last == "." else { return nil }
        t = t.dropLast()
        let letters = t.reversed().prefix { $0.isLetter }
        let token = String(letters.reversed())
        return token.isEmpty ? nil : token.lowercased()
    }
```

Then, after building `sentences` in `segment(...)`, merge forward across abbreviation ends (replace the `guard let last`/return block):

```swift
        // Merge a sentence into the following one when it ends on a known
        // abbreviation the tokenizer wrongly treated as a boundary.
        let abbr = abbreviations(for: language)
        var merged: [String] = []
        for s in sentences {
            if let prev = merged.last,
               let tok = trailingDottedToken(prev), abbr.contains(tok) {
                merged[merged.count - 1] = prev + " " + s
            } else {
                merged.append(s)
            }
        }
        guard let last = merged.last else { return ([], "") }
        if endsWithTerminator(last) {
            return (merged, "")
        }
        return (Array(merged.dropLast()), last)
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "segmenter_"`
Expected: PASS (all segmenter tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/SentenceSegmenter.swift Tests/UnisonDomainTests/SentenceSegmenterTests.swift
git commit -m "SentenceSegmenter: abbreviation guard (ru/pt/en/de/es); CJK + danda covered"
```

---

## Phase 2 — TranscriptModel (segment/commit engine)

### Task 3: TranscriptDelta carries a language

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptEntry.swift`
- Test: (compile-only; covered by later tests)

- [ ] **Step 1: Add the field**

In `TranscriptDelta`, add `public let language: Language?` and a default in the initializer:

```swift
public struct TranscriptDelta: Sendable, Equatable {
    public enum Kind: String, Sendable { case original, translated }
    public let entryId: UUID
    public let speaker: Speaker
    public let kind: Kind
    public let text: String
    public let isFinal: Bool
    public let language: Language?

    public init(entryId: UUID, speaker: Speaker, kind: Kind, text: String,
                isFinal: Bool, language: Language? = nil) {
        self.entryId = entryId; self.speaker = speaker; self.kind = kind
        self.text = text; self.isFinal = isFinal; self.language = language
    }
}
```

- [ ] **Step 2: Build to verify existing callers still compile** (the default keeps them valid)

Run: `swift build`
Expected: Build complete.

- [ ] **Step 3: Commit**

```bash
git add Sources/UnisonDomain/TranscriptEntry.swift
git commit -m "TranscriptDelta: optional language field (source/target of the chunk)"
```

### Task 4: TranscriptModel — accumulate a per-speaker live segment

**Files:**
- Create: `Sources/UnisonDomain/TranscriptModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import UnisonDomain

@MainActor
private func model(_ clock: FakeClock) -> TranscriptModel {
    let m = TranscriptModel(clock: clock)
    m.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    return m
}

@MainActor @Test func model_accumulatesLiveSegmentPerSpeaker() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Hello there", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Привет", isFinal: false, language: .ru))
    let b = m.bubbles
    #expect(b.count == 1)
    #expect(b[0].isLive == true)
    #expect(b[0].source == "Hello there")
    #expect(b[0].translation == "Привет")
    #expect(b[0].speaker == .peer)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "model_accumulatesLiveSegmentPerSpeaker"`
Expected: FAIL — `TranscriptModel` not defined.

- [ ] **Step 3: Minimal implementation**

```swift
import Foundation
import Observation

public struct TranscriptBubble: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let source: String
    public let translation: String
    public let translationLost: Bool
    public let committedAt: Date
    public let isLive: Bool
}

@MainActor
@Observable
public final class TranscriptModel {
    public var currentLanguagePair: LanguagePair?
    private let clock: Clock

    /// Per-speaker accumulator for the current (still-forming) segment.
    private struct Segment {
        var source = ""
        var translation = ""
        var sourceLang: Language?
        var translationLang: Language?
        var lastSourceAt: Date?
        var lastTranslationAt: Date?
        let id: UUID
        let startedAt: Date
    }
    private var live: [Speaker: Segment] = [:]
    private var frozen: [TranscriptBubble] = []

    public init(clock: Clock = SystemClock()) { self.clock = clock }

    public func ingest(_ delta: TranscriptDelta) {
        guard !delta.text.isEmpty else { return }
        var seg = live[delta.speaker] ?? Segment(id: UUID(), startedAt: clock.now())
        switch delta.kind {
        case .original:
            seg.source = appendChunk(seg.source, delta.text)
            seg.sourceLang = delta.language ?? seg.sourceLang
            seg.lastSourceAt = clock.now()
        case .translated:
            seg.translation = appendChunk(seg.translation, delta.text)
            seg.translationLang = delta.language ?? seg.translationLang
            seg.lastTranslationAt = clock.now()
        }
        live[delta.speaker] = seg
    }

    /// Deltas are appended; leading/trailing spacing is the model's. Single-
    /// spaced join keeps clause fragments readable.
    private func appendChunk(_ acc: String, _ chunk: String) -> String {
        let a = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return c }
        if c.isEmpty { return a }
        return a + " " + c
    }

    /// Frozen bubbles (oldest→newest) followed by each speaker's live bubble.
    public var bubbles: [TranscriptBubble] {
        var out = frozen
        for (speaker, seg) in live where !(seg.source.isEmpty && seg.translation.isEmpty) {
            out.append(liveBubble(speaker, seg))
        }
        return out.sorted { $0.committedAt < $1.committedAt }
    }

    private func liveBubble(_ speaker: Speaker, _ seg: Segment) -> TranscriptBubble {
        TranscriptBubble(
            id: seg.id, speaker: speaker, source: seg.source, translation: seg.translation,
            translationLost: false,
            committedAt: seg.lastSourceAt ?? seg.lastTranslationAt ?? seg.startedAt,
            isLive: true)
    }

    public func clear() { live.removeAll(); frozen.removeAll() }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "model_accumulatesLiveSegmentPerSpeaker"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptModel.swift Tests/UnisonDomainTests/TranscriptModelTests.swift
git commit -m "TranscriptModel: per-speaker live segment accumulation"
```

### Task 5: Pause commits the segment and resets (rule 3 + pause=resync)

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func model_pauseFreezesSegment_andResets() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Hello there", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Привет", isFinal: false, language: .ru))
    // Both streams quiet for > pauseSeconds → segment freezes on tick.
    clock.advance(by: 3)
    m.tick(now: clock.now())
    #expect(m.bubbles.count == 1)
    #expect(m.bubbles[0].isLive == false)
    // A new utterance opens a fresh segment (no carried state).
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "How are you", isFinal: false, language: .en))
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[1].isLive == true)
    #expect(b[1].source == "How are you")
    #expect(b[0].id != b[1].id)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "model_pauseFreezesSegment_andResets"`
Expected: FAIL — no `tick`; bubble stays live.

- [ ] **Step 3: Implement `tick` + pause commit**

Add config + `tick` to `TranscriptModel`:

```swift
    public struct Config: Sendable {
        public var pauseSeconds: TimeInterval = 2.0
        public var maxSegmentChars: Int = 240
        public var translationLagTimeout: TimeInterval = 5.0
        public var historyCap: Int = 40
        public init() {}
    }
    public var config = Config()

    /// Time-driven commits (pause / translation-lag). Call ~1/s from the view.
    public func tick(now: Date) {
        for (speaker, seg) in Array(live) {   // snapshot: commit() mutates `live`
            if isQuiet(seg, now: now, for: config.pauseSeconds) {
                commit(speaker, seg, now: now)
            }
        }
    }

    private func isQuiet(_ seg: Segment, now: Date, for seconds: TimeInterval) -> Bool {
        let last = [seg.lastSourceAt, seg.lastTranslationAt].compactMap { $0 }.max()
        guard let last else { return false }
        return now.timeIntervalSince(last) >= seconds
    }

    /// Freeze the whole segment as ONE bubble (source↔translation paired as a
    /// unit — the same speech span) and reset the speaker's live segment.
    private func commit(_ speaker: Speaker, _ seg: Segment, now: Date) {
        let source = seg.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        live[speaker] = nil
        guard !(source.isEmpty && translation.isEmpty) else { return }
        frozen.append(TranscriptBubble(
            id: seg.id, speaker: speaker, source: source, translation: translation,
            translationLost: false, committedAt: now, isLive: false))
        if frozen.count > config.historyCap { frozen.removeFirst(frozen.count - config.historyCap) }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "model_pauseFreezesSegment_andResets"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptModel.swift Tests/UnisonDomainTests/TranscriptModelTests.swift
git commit -m "TranscriptModel: pause commits + resets the segment (resync anchor)"
```

### Task 6: Clean sentence-split within a segment when counts agree (rule 1)

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func model_matchedSentenceCounts_splitIntoPairedBubbles() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    // Two complete sentences on both sides, counts agree.
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "First one. Second one now.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Первое. Второе теперь.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 2)
    #expect(b[0].source == "First one." && b[0].translation == "Первое.")
    #expect(b[1].source == "Second one now." && b[1].translation == "Второе теперь.")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "model_matchedSentenceCounts_splitIntoPairedBubbles"`
Expected: FAIL — commit produces one merged bubble, not two.

- [ ] **Step 3: Split on commit when counts agree**

Replace `commit(...)` body's freeze section so it splits into sentence pairs when safe:

```swift
    private func commit(_ speaker: Speaker, _ seg: Segment, now: Date) {
        let source = seg.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let translation = seg.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        live[speaker] = nil
        guard !(source.isEmpty && translation.isEmpty) else { return }

        for (s, t) in pairs(source: source, translation: translation,
                            sourceLang: seg.sourceLang ?? defaultSourceLang(speaker),
                            translationLang: seg.translationLang ?? defaultTranslationLang(speaker)) {
            frozen.append(TranscriptBubble(
                id: UUID(), speaker: speaker, source: s, translation: t,
                translationLost: false, committedAt: now, isLive: false))
        }
        if frozen.count > config.historyCap { frozen.removeFirst(frozen.count - config.historyCap) }
    }

    /// Pair source↔translation for a committed segment. If both sides split
    /// into the SAME number of sentences, pair them 1:1 (nice, safe). If the
    /// counts differ, do NOT risk a wrong split — emit ONE whole-segment pair.
    private func pairs(source: String, translation: String,
                       sourceLang: Language, translationLang: Language) -> [(String, String)] {
        let src = SentenceSegmenter.segment(source, language: sourceLang)
        let tr = SentenceSegmenter.segment(translation, language: translationLang)
        let srcSentences = src.complete + (src.trailing.isEmpty ? [] : [src.trailing])
        let trSentences = tr.complete + (tr.trailing.isEmpty ? [] : [tr.trailing])
        if srcSentences.count == trSentences.count && srcSentences.count > 1 {
            return Array(zip(srcSentences, trSentences))
        }
        return [(source, translation)]
    }

    private func defaultSourceLang(_ speaker: Speaker) -> Language {
        // Original is the speaker's own language.
        guard let p = currentLanguagePair else { return .en }
        return speaker == .me ? p.mine : p.peer
    }
    private func defaultTranslationLang(_ speaker: Speaker) -> Language {
        guard let p = currentLanguagePair else { return .en }
        return speaker == .me ? p.peer : p.mine
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "model_"`
Expected: PASS (accumulation, pause, and split tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptModel.swift Tests/UnisonDomainTests/TranscriptModelTests.swift
git commit -m "TranscriptModel: split a committed segment into sentence pairs when counts agree"
```

### Task 7: Max-length safety commit (rule 2)

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func model_maxLength_forcesCommit_noInfiniteBubble() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.config.maxSegmentChars = 40
    // No punctuation, keeps growing.
    let chunk = "word word word word word word word "
    for _ in 0..<4 {
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                                 text: chunk, isFinal: false, language: .en))
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                                 text: chunk, isFinal: false, language: .en))
    }
    // No pause; but the segment must have been force-sealed at least once.
    #expect(m.bubbles.contains { !$0.isLive })
    #expect(m.bubbles.allSatisfy { $0.source.count <= 40 + chunk.count })
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "model_maxLength_forcesCommit_noInfiniteBubble"`
Expected: FAIL — nothing frozen; one growing live bubble.

- [ ] **Step 3: Force-commit on max length inside `ingest`**

At the end of `ingest`, after `live[delta.speaker] = seg`, add:

```swift
        if seg.source.count >= config.maxSegmentChars || seg.translation.count >= config.maxSegmentChars {
            commit(delta.speaker, seg, now: clock.now())
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "model_"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptModel.swift Tests/UnisonDomainTests/TranscriptModelTests.swift
git commit -m "TranscriptModel: max-length safety commit (no infinite bubble)"
```

### Task 8: Translation-lag commit + translationLost (rule 4)

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func model_translationNeverArrives_commitsWithLostMarker() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "Hello there.", isFinal: false, language: .en))
    // Translation never comes; after lag timeout, commit source-only.
    clock.advance(by: 6); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 1)
    #expect(b[0].source == "Hello there.")
    #expect(b[0].translation.isEmpty)
    #expect(b[0].translationLost == true)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "model_translationNeverArrives_commitsWithLostMarker"`
Expected: FAIL — `translationLost` stays false (pause commit already fires at 6 s, so this checks the flag).

- [ ] **Step 3: Set the lost flag on commit; and commit on lag even if source is still active**

Replace the `tick` loop body (the lag check comes before the pause check):

```swift
        for (speaker, seg) in Array(live) {   // snapshot: commit() mutates `live`
            let sourceQuiet = seg.lastSourceAt.map { now.timeIntervalSince($0) >= config.pauseSeconds } ?? true
            let hasSource = !seg.source.isEmpty
            let translationBehind = seg.translation.count < seg.source.count / 2
            if hasSource && sourceQuiet && translationBehind
                && (seg.lastTranslationAt.map { now.timeIntervalSince($0) >= config.translationLagTimeout } ?? true) {
                commit(speaker, seg, now: now); continue
            }
            if isQuiet(seg, now: now, for: config.pauseSeconds) { commit(speaker, seg, now: now) }
        }
```

And in `commit`, when emitting the whole-segment pair, mark lost when translation is empty:

```swift
        for (s, t) in pairs(...) {
            frozen.append(TranscriptBubble(
                id: UUID(), speaker: speaker, source: s, translation: t,
                translationLost: t.isEmpty && !s.isEmpty,
                committedAt: now, isLive: false))
        }
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "model_"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptModel.swift Tests/UnisonDomainTests/TranscriptModelTests.swift
git commit -m "TranscriptModel: translation-lag commit with lost marker"
```

### Task 9: Count-mismatch → whole-segment (rule 5) + no-drift regression

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptModel.swift` (no code change expected — `pairs` already collapses on mismatch; this task PROVES the invariant)
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing/guard tests**

```swift
@MainActor @Test func model_mismatchedSentenceCounts_stayWholeSegment() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    // Source: 2 sentences; translation merged into 1 → counts differ.
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "First one. Second one.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Первое и второе вместе.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 1)   // NOT split into a wrong pair
    #expect(b[0].source == "First one. Second one.")
    #expect(b[0].translation == "Первое и второе вместе.")
}

// A bad/mismatched segment must NOT poison the next one — each segment is
// independent (pause resets alignment).
@MainActor @Test func model_badSegment_doesNotDriftNext() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "First one. Second one.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Первое и второе.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    // New, clean segment.
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original,
                             text: "All good now.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated,
                             text: "Теперь всё хорошо.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.last?.source == "All good now.")
    #expect(b.last?.translation == "Теперь всё хорошо.")   // correctly paired, no carryover
}
```

- [ ] **Step 2: Run to verify status**

Run: `scripts/test.sh --filter "model_mismatchedSentenceCounts_stayWholeSegment|model_badSegment_doesNotDriftNext"`
Expected: PASS (the `pairs` count-guard + per-segment reset already give this). If any fails, fix `pairs`/`commit` — do NOT add cross-segment state.

- [ ] **Step 3: Commit**

```bash
git add Tests/UnisonDomainTests/TranscriptModelTests.swift Sources/UnisonDomain/TranscriptModel.swift
git commit -m "TranscriptModel: prove mismatch→whole-segment and no cross-segment drift"
```

### Task 10: Cross-speaker ordering + live/append-vs-replace

**Files:**
- Modify: `Sources/UnisonDomain/TranscriptModel.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor @Test func model_ordersBubblesByTime_acrossSpeakers() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hi.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Привет.", isFinal: false, language: .ru))
    clock.advance(by: 3); m.tick(now: clock.now())
    clock.advance(by: 1)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .original, text: "Да.", isFinal: false, language: .ru))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "Yes.", isFinal: false, language: .en))
    clock.advance(by: 3); m.tick(now: clock.now())
    let b = m.bubbles
    #expect(b.count == 2)
    #expect(b[0].speaker == .peer && b[1].speaker == .me)
}

@MainActor @Test func model_cumulativeRestatement_replacesNotAppends() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hello", isFinal: false, language: .en))
    // Some models re-send the cumulative transcript: "Hello world" contains "Hello".
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hello world", isFinal: false, language: .en))
    #expect(m.bubbles.first?.source == "Hello world")   // replaced, not "Hello Hello world"
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "model_cumulativeRestatement_replacesNotAppends"`
Expected: FAIL — source becomes "Hello Hello world" (append). (Ordering test likely passes already.)

- [ ] **Step 3: append-vs-replace in `appendChunk`**

Replace `appendChunk` to detect cumulative restatement:

```swift
    private func appendChunk(_ acc: String, _ chunk: String) -> String {
        let a = acc.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return c }
        if c.isEmpty { return a }
        // Cumulative restatement (some models resend the whole transcript):
        // the new chunk already contains the accumulation → replace.
        if c.hasPrefix(a) { return c }
        return a + " " + c
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "model_"`
Expected: PASS (all model tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonDomain/TranscriptModel.swift Tests/UnisonDomainTests/TranscriptModelTests.swift
git commit -m "TranscriptModel: time ordering across speakers; cumulative-restatement replace"
```

---

## Phase 3 — Integration

### Task 11: Gemini events carry languageCode

**Files:**
- Modify: `Sources/UnisonTranslation/GeminiEvents.swift`
- Test: `Tests/UnisonTranslationTests/GeminiEventsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func decodesTranscriptLanguageCode() throws {
    #expect(try decodeGeminiFrame(#"{"serverContent":{"inputTranscription":{"text":"hi","languageCode":"en"}}}"#)
            == [.inputTranscript("hi", "en")])
    #expect(try decodeGeminiFrame(#"{"serverContent":{"outputTranscription":{"text":"привет","languageCode":"ru"}}}"#)
            == [.outputTranscript("привет", "ru")])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "decodesTranscriptLanguageCode"`
Expected: FAIL — cases have no language associated value.

- [ ] **Step 3: Add language to the events**

In `GeminiServerEvent`: `case inputTranscript(String, String?)` / `case outputTranscript(String, String?)`. Update the two `Text` decode branches in `GeminiServerFrame.init` to also read `languageCode` (add `languageCode` to the `Text` CodingKeys) and append `.inputTranscript(text, lang)` / `.outputTranscript(text, lang)`. Update all existing `.inputTranscript(text)` / `.outputTranscript(text)` matches in `GeminiEventsTests.swift` (add `nil`) and in the stream (Task 12).

```swift
    private enum Text: String, CodingKey { case text, languageCode }
    // ...
    if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .inputTranscription),
       let text = try? t.decode(String.self, forKey: .text) {
        out.append(.inputTranscript(text, try? t.decode(String.self, forKey: .languageCode)))
    }
    if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .outputTranscription),
       let text = try? t.decode(String.self, forKey: .text) {
        out.append(.outputTranscript(text, try? t.decode(String.self, forKey: .languageCode)))
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "Gemini"`
Expected: PASS (update the other decode tests' expected values to include `nil` where no languageCode).

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonTranslation/GeminiEvents.swift Tests/UnisonTranslationTests/GeminiEventsTests.swift
git commit -m "Gemini events: carry transcription languageCode"
```

### Task 12: Gemini stream emits raw deltas with language; delete the FIFO

**Files:**
- Modify: `Sources/UnisonTranslation/GeminiLiveTranslateStream.swift`
- Test: `Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@Test func stream_emitsRawDeltasWithLanguage_noFIFO() async throws {
    let ws = FakeWSClient()
    let stream = GeminiLiveTranslateStream(apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
    try await stream.connect(target: .ru)
    var it = stream.transcripts.makeAsyncIterator()
    ws.push(.text(#"{"serverContent":{"inputTranscription":{"text":"hi","languageCode":"en"}}}"#))
    let d1 = await it.next()
    ws.push(.text(#"{"serverContent":{"outputTranscription":{"text":"привет","languageCode":"ru"}}}"#))
    let d2 = await it.next()
    #expect(d1?.kind == .original && d1?.text == "hi" && d1?.language == .en)
    #expect(d2?.kind == .translated && d2?.text == "привет" && d2?.language == .ru)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "stream_emitsRawDeltasWithLanguage_noFIFO"`
Expected: FAIL — deltas carry no language; case signatures changed.

- [ ] **Step 3: Simplify the stream**

Delete: `inputEntryId`, `pendingTurnEntries`, `sawOutputForCurrentInput`, `lastInputDeltaAt`, `rotateInputEntryIfNewUtterance`, `markOutputStartedForCurrentTurn`, `maxPendingTurnEntries`, `turnGapSeconds`, `interUtteranceGapSeconds`, and the `.turnComplete` FIFO body (keep a `[turn]` log line if desired). Replace the `.inputTranscript`/`.outputTranscript` cases:

```swift
        case .inputTranscript(let text, let lang):
            receivedAnyData = true
            transcriptContinuation.yield(TranscriptDelta(
                entryId: UUID(), speaker: speaker, kind: .original, text: text,
                isFinal: false, language: lang.flatMap(Language.init(rawValue:))))
        case .outputTranscript(let text, let lang):
            receivedAnyData = true
            markOutputStarted()   // keep only if still used elsewhere; else drop
            transcriptContinuation.yield(TranscriptDelta(
                entryId: UUID(), speaker: speaker, kind: .translated, text: text,
                isFinal: false, language: lang.flatMap(Language.init(rawValue:))))
        case .turnComplete:
            break
```

Delete the now-broken pairing tests in `GeminiLiveTranslateStreamTests.swift` (`lateTranslation_*`, `streamingInterleave_*`, `twoQueuedUtterances_*`, `turnCompleteRotatesEntryId`, `bundledTurnComplete_keepsPairingAligned`) — pairing now lives in `TranscriptModel`, tested there.

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "Gemini"` then `swift build`
Expected: PASS; build clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonTranslation/GeminiLiveTranslateStream.swift Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift
git commit -m "Gemini stream: emit raw language-tagged deltas; delete two-track FIFO"
```

### Task 13: Wire TranscriptModel into the view model

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/TranscriptViewModel.swift`
- Modify: `Sources/UnisonUI/TranscriptGrouping.swift` (keep only `groupDisplayBubbles`; move `DisplayBubble` if needed)
- Modify: `Sources/UnisonApp/Composition.swift`
- Test: `Tests/UnisonDomainTests/TranscriptViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
@MainActor @Test func vm_rendersModelBubblesAsGroups() {
    let clock = FakeClock(now: epochDate(1000))
    let m = TranscriptModel(clock: clock)
    m.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    let vm = TranscriptViewModel(model: m)
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .original, text: "Hi there.", isFinal: false, language: .en))
    m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Привет.", isFinal: false, language: .ru))
    let groups = vm.visibleBubbleGroups(at: clock.now())
    #expect(groups.count == 1)
    #expect(groups[0].speaker == .peer)
    #expect(groups[0].bubbles.last?.primaryText == "Привет.")   // peer: translation bold
    #expect(groups[0].bubbles.last?.secondaryText == "Hi there.")
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `scripts/test.sh --filter "vm_rendersModelBubblesAsGroups"`
Expected: FAIL — `TranscriptViewModel(model:)` doesn't exist.

- [ ] **Step 3: Map model bubbles → DisplayBubble → groups**

Replace the VM's `store` with `model: TranscriptModel` — new init `public init(model: TranscriptModel, orchestrator: TranslationOrchestrator? = nil)` (the `orchestrator` param and everything it drives — pill timer, `isTestMode`, stop-modal — stays). The `feed` stays but is fed a pre-built list (see below). Map each `TranscriptBubble` to a `DisplayBubble` (peer: primary=translation, secondary=source; me: primary=source, secondary=translation), pass through `TranscriptFeed` for whole-unit expiry (map `committedAt`→`lastActivityAt`), then `groupDisplayBubbles`. Keep `bubbleScale`, pill, stop-modal, etc. In `Composition`, build `TranscriptModel`, set `currentLanguagePair`, subscribe the streams' `transcripts` to `model.ingest`, and drive `model.tick(now:)` from the same 1 s `TimelineView` clock the view already uses.

```swift
    public func visibleBubbleGroups(at now: Date) -> [BubbleGroup] {
        model.tick(now: now)
        let display = model.bubbles.map { b -> DisplayBubble in
            DisplayBubble(
                id: b.id, speaker: b.speaker,
                primaryText: b.speaker == .me ? b.source : b.translation,
                secondaryText: b.speaker == .me ? b.translation : b.source,
                isLive: b.isLive, translationLost: b.translationLost,
                lastActivityAt: b.committedAt)
        }
        let visible = windowingEnabled ? feed.visible(display, now: now) : display
        return TranscriptGrouping.groupDisplayBubbles(visible)
    }
```

(Adjust `TranscriptFeed` to accept a pre-built `[DisplayBubble]` list — a small refactor of its `visibleBubbles(entries:now:)` into `visible(_ all:[DisplayBubble], now:)`.)

- [ ] **Step 4: Run to verify it passes**

Run: `scripts/test.sh --filter "vm_|feed_|groupDisplay_"` then `swift build`
Expected: PASS; build clean.

- [ ] **Step 5: Commit**

```bash
git add Sources/UnisonUI Sources/UnisonApp/Composition.swift Tests/UnisonDomainTests/TranscriptViewModelTests.swift
git commit -m "Wire TranscriptModel into the transcript view model + composition"
```

### Task 14: Delete legacy

**Files:**
- Delete: `Sources/UnisonDomain/TranscriptStore.swift`, `Tests/UnisonDomainTests/TranscriptStoreTests.swift`
- Modify: `Sources/UnisonUI/TranscriptGrouping.swift` (remove `liveBubbles`, `utteranceGroups`, `endsSentence`, `speakerRuns`, `reconstructRunText`, `DisplayBubble` split logic — keep `groupDisplayBubbles` + `DisplayBubble` struct)
- Modify: `Tests/UnisonDomainTests/TranscriptGroupingTests.swift` (delete `liveBubbles_*`; keep `groupDisplay_*`)
- Grep for stragglers.

- [ ] **Step 1: Delete + grep**

```bash
git rm Sources/UnisonDomain/TranscriptStore.swift Tests/UnisonDomainTests/TranscriptStoreTests.swift
grep -rn "TranscriptStore\|liveBubbles\|utteranceGroups" Sources Tests
```
Fix every reference (streams/orchestrator that used `TranscriptStore` now feed `TranscriptModel`; the orchestrator holds a `TranscriptModel` instead).

- [ ] **Step 2: Build + full suite**

Run: `swift build` then `scripts/test.sh`
Expected: build clean; all tests pass.

- [ ] **Step 3: Lint**

Run: `scripts/lint.sh swiftlint`
Expected: Lint clean.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "Remove legacy TranscriptStore + old grouping (superseded by TranscriptModel)"
```

### Task 15: Offline regression from a recorded frame sequence

**Files:**
- Modify: `Tests/UnisonDomainTests/Mocks/FakeClock.swift`
- Test: `Tests/UnisonDomainTests/TranscriptModelTests.swift`

- [ ] **Step 1: Add `set(_:)` to `FakeClock`**

`FakeClock` currently only has `advance(by:)`; the regression uses absolute timestamps. Add:

```swift
    public func set(_ date: Date) {
        lock.lock(); let forward = date > current; current = date
        let due = pending.filter { $0.deadline <= current }
        pending.removeAll { $0.deadline <= current }
        lock.unlock()
        if forward { for d in due { d.continuation.resume() } }
    }
```

- [ ] **Step 2: Write the regression test**

Encode the real captured timeline (from the spec §2) as a delta sequence with timestamps and assert the resulting bubbles pair correctly and segment on the 5 s pause:

```swift
@MainActor @Test func model_recordedGeminiTimeline_pairsCorrectly() {
    let clock = FakeClock(now: epochDate(0))
    let m = model(clock)
    func at(_ t: Double, _ kind: TranscriptDelta.Kind, _ text: String, _ lang: Language) {
        clock.set(epochDate(t))
        m.ingest(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: kind, text: text, isFinal: false, language: lang))
    }
    at(6.083, .original, "First, we look at a simple idea.", .en)
    at(6.451, .translated, "Сначала мы рассмотрим", .ru)
    at(7.159, .translated, " простую идею.", .ru)
    at(7.536, .original, " Then we", .en)
    at(9.598, .original, " make it more complex.", .en)
    at(10.278, .translated, " Затем мы делаем ее более сложной.", .ru)
    clock.set(epochDate(14.0)); m.tick(now: clock.now())   // 5 s pause → commit
    let b = m.bubbles.filter { !$0.isLive }
    #expect(b.count == 2)
    #expect(b[0].source.contains("simple idea") && b[0].translation.contains("простую идею"))
    #expect(b[1].source.contains("more complex") && b[1].translation.contains("сложной"))
}
```

- [ ] **Step 3: Run to verify it passes**

Run: `scripts/test.sh --filter "model_recordedGeminiTimeline_pairsCorrectly"`
Expected: PASS. If it doesn't, the segment/pairing rules need adjusting — fix in `TranscriptModel`, not the test.

- [ ] **Step 4: Full verification**

Run: `scripts/test.sh` ; `scripts/lint.sh swiftlint` ; `swift build`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Tests/UnisonDomainTests/TranscriptModelTests.swift Tests/UnisonDomainTests/Mocks/FakeClock.swift
git commit -m "TranscriptModel: offline regression from recorded Gemini timeline"
```

---

## Self-review notes

- **Spec coverage:** §4.1 SentenceSegmenter → T1–2; §4.2 TranscriptModel + §6 rules → T4–10 (rule1 T6, rule2 T7, rule3 T5, rule4 T8, rule5 T9); §4.3 stream → T11–12; §4.4 UI → T13; §9 legacy removal → T14; §10 offline regression → T15; §2 languageCode → T3/T11. Covered.
- **OpenAI (spec §11):** out of scope for this plan (Gemini-first). After T15, run the same raw-frame capture against OpenAI and, if its delta/pause semantics match, no code change is needed; otherwise a follow-up plan tags OpenAI deltas with language and confirms punctuation. Noted, not silently dropped.
- **Thresholds** live in `TranscriptModel.Config`; wire env-var overrides during T13 if desired.
