# Translation Model Selection (OpenAI / Gemini) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick the translation engine — OpenAI `gpt-realtime-translate` (current) or Google `gemini-3.5-live-translate-preview` — in Onboarding and Settings, with the two engines plugged into the existing `TranslationStream` seam.

**Architecture:** New `GeminiLiveTranslateStream: TranslationStream` actor mirrors `OpenAIRealtimeStream`; a provider-aware factory picks the engine from `Settings.translationModel`. The orchestrator stays provider-agnostic (only the input wire sample rate is parameterized: 24 kHz for OpenAI, 16 kHz for Gemini; both output 24 kHz). Two independent Keychain slots hold the two API keys. Target-language lists become per-model (OpenAI 13, Gemini ~28).

**Tech Stack:** Swift 6.2 toolchain / Swift 5 language mode, SwiftPM, `swift-testing` (`import Testing`), `URLSessionWebSocketTask`, AVFoundation (`AVAudioConverter`), SwiftUI + AppKit, macOS 26.

**Spec:** `docs/superpowers/specs/2026-06-29-translation-model-selection-design.md`

**Conventions for the executor:**
- Build: `swift build`. Tests: `swift test` (whole suite) or `swift test --filter <Suite>/<test>`.
- Lint: `swiftlint` (config `.swiftlint.yml`). Run before each commit; zero new warnings.
- Tests use `import Testing` + `#expect(...)` / `@Test` / `@Suite`. Translation tests deliberately avoid `import Foundation` in the test file (cross-import overlay issue) — put Foundation-touching helpers in `Tests/UnisonTranslationTests/Helpers.swift`.
- Commit style: conventional commits, e.g. `feat(domain): …`, `feat(ui): …`, `test(translation): …`.
- After each task: `swift build && swift test` green, `swiftlint` clean, then commit.

---

## File Structure

**New files**
- `Sources/UnisonDomain/TranslationModel.swift` — the engine enum + per-engine metadata + language coercion.
- `Sources/UnisonTranslation/GeminiEvents.swift` — Codable client/server JSON envelopes for the Gemini Live API.
- `Sources/UnisonTranslation/GeminiLiveTranslateStream.swift` — `TranslationStream` actor for Gemini.
- `Tests/UnisonDomainTests/TranslationModelTests.swift`
- `Tests/UnisonTranslationTests/GeminiEventsTests.swift`
- `Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift`

**Modified files**
- `Sources/UnisonDomain/Language.swift` — +15 cases, `displayName`, `isTargetSupported`, `openAITargets`/`geminiTargets`.
- `Sources/UnisonUI/Extensions/Language+Flag.swift` — +15 `flagEmoji` cases.
- `Sources/UnisonDomain/Settings.swift` — `translationModel` field + decode.
- `Sources/UnisonDomain/Protocols/TranslationStream.swift` — `inputWireSampleRate` requirement + default.
- `Sources/UnisonDomain/Protocols/AudioFormatTransformer.swift` — `toWire(_:sampleRate:)`.
- `Sources/UnisonDomain/Protocols/KeychainService.swift` — methods parameterized by `TranslationModel`.
- `Sources/UnisonDomain/TranslationOrchestrator.swift` — 2 `toWire` call sites.
- `Sources/UnisonAudio/Resampler.swift` — `toOpenAIWire`→`toWire(_:targetSampleRate:)`, `fromOpenAIWire`→`fromWire`.
- `Sources/UnisonAudio/ResamplerAdapter.swift` — conform to new transformer API.
- `Sources/UnisonTranslation/OpenAIRealtimeStream.swift` — (no behavior change; inherits default 24 kHz).
- `Sources/UnisonSystem/MacKeychain.swift` — per-account ops.
- `Sources/UnisonApp/Composition.swift` — provider-aware factory, keychain stub, `apiKeyProvider`.
- `Sources/UnisonApp/DiagnosticCollector.swift` — keychain call site.
- `Sources/UnisonUI/Views/SettingsView.swift` — «Модель перевода» section + model-driven language picker.
- `Sources/UnisonUI/ViewModels/SettingsViewModel.swift` — model state, coercion, per-model key.
- `Sources/UnisonUI/Views/OnboardingView.swift` — provider selector in key card.
- `Sources/UnisonUI/ViewModels/OnboardingViewModel.swift` — model-aware validate/save/gate.
- `Sources/UnisonUI/Views/PopoverView.swift` — language picker uses model targets.
- `Sources/Tools/PacingEval/Session.swift` + `main.swift` — `--provider` for live verification.
- `docs/audio-pipeline.md`, `README.md` — documentation.

---

## Task 1: Expand `Language` with Gemini target languages

**Files:**
- Modify: `Sources/UnisonDomain/Language.swift`
- Modify: `Sources/UnisonUI/Extensions/Language+Flag.swift`
- Test: `Tests/UnisonDomainTests/TranslationModelTests.swift` (created here; extended in Task 2)

- [ ] **Step 1: Write failing test for the new cases and target lists**

Create `Tests/UnisonDomainTests/TranslationModelTests.swift`:

```swift
import Testing
@testable import UnisonDomain

@Suite struct LanguageExpansionTests {
    @Test func newGeminiLanguagesExist() {
        // rawValue == BCP-47 / ISO-639-1 code, used directly by both providers.
        #expect(Language(rawValue: "pl") == .pl)
        #expect(Language(rawValue: "uk") == .uk)
        #expect(Language(rawValue: "ar") == .ar)
        #expect(Language.pl.displayName == "Polski")
        #expect(Language.uk.displayName == "Українська")
    }

    @Test func openAITargetsAreTheCanonicalThirteen() {
        #expect(Language.openAITargets.count == 13)
        #expect(Language.openAITargets.contains(.ru))
        #expect(!Language.openAITargets.contains(.pl)) // Polish is Gemini-only
    }

    @Test func geminiTargetsSupersetOfOpenAI() {
        for lang in Language.openAITargets {
            #expect(Language.geminiTargets.contains(lang))
        }
        #expect(Language.geminiTargets.count > Language.openAITargets.count)
        #expect(Language.geminiTargets.contains(.pl))
    }
}
```

- [ ] **Step 2: Run it, verify it fails to compile**

Run: `swift test --filter UnisonDomainTests.LanguageExpansionTests`
Expected: FAIL — `type 'Language' has no member 'pl'` / `openAITargets`.

- [ ] **Step 3: Add the cases + displayName**

In `Sources/UnisonDomain/Language.swift`, extend the `case` line:

```swift
public enum Language: String, CaseIterable, Codable, Sendable {
    case ru, en, es, fr, de, it, pt, zh, ja, ko, hi, id, vi
    // Gemini-only targets (curated subset of its 70+).
    case pl, nl, tr, ar, uk, he, th, sv, no, da, fi, cs, el, ro, hu
```

Add to the `displayName` switch (endonyms, matching existing style):

```swift
        case .pl: "Polski"
        case .nl: "Nederlands"
        case .tr: "Türkçe"
        case .ar: "العربية"
        case .uk: "Українська"
        case .he: "עברית"
        case .th: "ไทย"
        case .sv: "Svenska"
        case .no: "Norsk"
        case .da: "Dansk"
        case .fi: "Suomi"
        case .cs: "Čeština"
        case .el: "Ελληνικά"
        case .ro: "Română"
        case .hu: "Magyar"
```

Add the new cases to the `isTargetSupported` switch (all are valid targets for at least one model):

```swift
        case .ru, .en, .es, .fr, .de, .it, .pt, .zh, .ja, .ko, .hi, .id, .vi,
             .pl, .nl, .tr, .ar, .uk, .he, .th, .sv, .no, .da, .fi, .cs, .el, .ro, .hu:
            return true
```

Append the per-model target lists (replace the existing `supportedTargets` static doc to point at the model lists, but keep `supportedTargets` returning the OpenAI set for any legacy caller):

```swift
    /// Output languages OpenAI `gpt-realtime-translate` honors (the
    /// canonical 13 per the cookbook). Stable list — do NOT derive from
    /// `allCases`, which now also contains Gemini-only targets.
    public static let openAITargets: [Language] =
        [.ru, .en, .es, .pt, .fr, .ja, .zh, .de, .ko, .hi, .id, .vi, .it]

    /// Gemini 3.5 Live Translate target set (curated subset of its 70+).
    public static var geminiTargets: [Language] { allCases }

    /// Legacy alias — the picker now reads `TranslationModel.supportedTargets`.
    public static var supportedTargets: [Language] { openAITargets }
```

- [ ] **Step 4: Add flag emojis (UnisonUI)**

In `Sources/UnisonUI/Extensions/Language+Flag.swift`, add to the `flagEmoji` switch (🌐 for languages with no single representative country flag):

```swift
        case .pl: "🇵🇱"
        case .nl: "🇳🇱"
        case .tr: "🇹🇷"
        case .ar: "🌐"
        case .uk: "🇺🇦"
        case .he: "🇮🇱"
        case .th: "🇹🇭"
        case .sv: "🇸🇪"
        case .no: "🇳🇴"
        case .da: "🇩🇰"
        case .fi: "🇫🇮"
        case .cs: "🇨🇿"
        case .el: "🇬🇷"
        case .ro: "🇷🇴"
        case .hu: "🇭🇺"
```

- [ ] **Step 5: Run tests, verify pass + build green**

Run: `swift build && swift test --filter UnisonDomainTests.LanguageExpansionTests`
Expected: PASS. (Build proves both exhaustive switches — `displayName`, `isTargetSupported`, `flagEmoji` — handle the new cases.)

- [ ] **Step 6: Lint + commit**

```bash
swiftlint
git add Sources/UnisonDomain/Language.swift Sources/UnisonUI/Extensions/Language+Flag.swift Tests/UnisonDomainTests/TranslationModelTests.swift
git commit -m "feat(domain): expand Language with Gemini target languages + flags"
```

---

## Task 2: `TranslationModel` enum

**Files:**
- Create: `Sources/UnisonDomain/TranslationModel.swift`
- Test: `Tests/UnisonDomainTests/TranslationModelTests.swift` (extend)

- [ ] **Step 1: Write failing tests**

Append to `Tests/UnisonDomainTests/TranslationModelTests.swift`:

```swift
@Suite struct TranslationModelTests {
    @Test func metadataPerModel() {
        #expect(TranslationModel.openAIRealtime.keychainAccount == "openai-api-key")
        #expect(TranslationModel.geminiLiveTranslate.keychainAccount == "gemini-api-key")
        #expect(TranslationModel.openAIRealtime.inputWireSampleRate == 24_000)
        #expect(TranslationModel.geminiLiveTranslate.inputWireSampleRate == 16_000)
        #expect(TranslationModel.openAIRealtime.acceptedKeyPrefixes == ["sk-"])
        #expect(TranslationModel.geminiLiveTranslate.acceptedKeyPrefixes.contains("AQ."))
        #expect(TranslationModel.geminiLiveTranslate.acceptedKeyPrefixes.contains("AIza"))
    }

    @Test func supportedTargetsPerModel() {
        #expect(TranslationModel.openAIRealtime.supportedTargets == Language.openAITargets)
        #expect(TranslationModel.geminiLiveTranslate.supportedTargets.contains(.pl))
    }

    @Test func coerceLeavesSupportedPairUntouched() {
        let pair = LanguagePair(mine: .ru, peer: .en)
        #expect(TranslationModel.openAIRealtime.coerced(pair) == pair)
    }

    @Test func coerceReplacesUnsupportedLanguage() {
        // Polish is Gemini-only; switching to OpenAI must replace it.
        let pair = LanguagePair(mine: .pl, peer: .en)
        let fixed = TranslationModel.openAIRealtime.coerced(pair)
        #expect(TranslationModel.openAIRealtime.supportedTargets.contains(fixed.mine))
        #expect(fixed.peer == .en)
    }

    @Test func coerceAvoidsCollapsingToSameLanguage() {
        // Both unsupported → must not become mine == peer.
        let pair = LanguagePair(mine: .pl, peer: .uk)
        let fixed = TranslationModel.openAIRealtime.coerced(pair)
        #expect(fixed.mine != fixed.peer)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonDomainTests.TranslationModelTests`
Expected: FAIL — `cannot find 'TranslationModel' in scope`.

- [ ] **Step 3: Create the enum**

Create `Sources/UnisonDomain/TranslationModel.swift`:

```swift
import Foundation

/// Which realtime translation engine a session uses. Flat enum (one model
/// per provider today); extends by adding a case. Persisted in `Settings`.
public enum TranslationModel: String, CaseIterable, Codable, Sendable {
    case openAIRealtime        // gpt-realtime-translate
    case geminiLiveTranslate   // gemini-3.5-live-translate-preview

    public var displayName: String {
        switch self {
        case .openAIRealtime: "OpenAI Realtime"
        case .geminiLiveTranslate: "Gemini 3.5 Live Translate"
        }
    }

    /// Keychain account (service is constant `com.unison.app`). The two
    /// engines store their keys in independent slots.
    public var keychainAccount: String {
        switch self {
        case .openAIRealtime: "openai-api-key"
        case .geminiLiveTranslate: "gemini-api-key"
        }
    }

    /// Prefixes accepted by key validation. Google issues both new `AQ.`
    /// auth keys and legacy `AIza` keys — accept both so a valid legacy
    /// key isn't rejected.
    public var acceptedKeyPrefixes: [String] {
        switch self {
        case .openAIRealtime: ["sk-"]
        case .geminiLiveTranslate: ["AQ.", "AIza"]
        }
    }

    public var apiKeyPlaceholder: String {
        switch self {
        case .openAIRealtime: "sk-proj-…"
        case .geminiLiveTranslate: "AQ.… / AIza…"
        }
    }

    public var getKeyURL: URL {
        switch self {
        case .openAIRealtime: URL(string: "https://platform.openai.com/api-keys")!
        case .geminiLiveTranslate: URL(string: "https://aistudio.google.com/apikey")!
        }
    }

    /// PCM sample rate (Hz) the engine expects on the input wire. Output
    /// is 24 kHz for both, so only the input differs.
    public var inputWireSampleRate: Int {
        switch self {
        case .openAIRealtime: 24_000
        case .geminiLiveTranslate: 16_000
        }
    }

    /// Languages selectable as a translation target for this engine.
    public var supportedTargets: [Language] {
        switch self {
        case .openAIRealtime: Language.openAITargets
        case .geminiLiveTranslate: Language.geminiTargets
        }
    }

    /// Coerce a pair so both sides are supported targets of this engine.
    /// Each unsupported language is replaced with a supported one, picking
    /// a distinct fallback so the pair never collapses to mine == peer.
    public func coerced(_ pair: LanguagePair) -> LanguagePair {
        let supported = supportedTargets
        func fix(_ lang: Language, avoiding other: Language) -> Language {
            if supported.contains(lang) { return lang }
            return supported.first(where: { $0 != other }) ?? supported.first ?? lang
        }
        let mine = fix(pair.mine, avoiding: pair.peer)
        let peer = fix(pair.peer, avoiding: mine)
        return LanguagePair(mine: mine, peer: peer)
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `swift build && swift test --filter UnisonDomainTests.TranslationModelTests`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint
git add Sources/UnisonDomain/TranslationModel.swift Tests/UnisonDomainTests/TranslationModelTests.swift
git commit -m "feat(domain): add TranslationModel enum with per-engine metadata"
```

---

## Task 3: `Settings.translationModel` field + decode

**Files:**
- Modify: `Sources/UnisonDomain/Settings.swift`
- Test: `Tests/UnisonDomainTests/SettingsTests.swift` (create or extend — check if it exists first with `ls Tests/UnisonDomainTests/`)

- [ ] **Step 1: Write failing tests**

Add to `Tests/UnisonDomainTests/SettingsTests.swift` (create the file with this content if absent):

```swift
import Testing
import Foundation
@testable import UnisonDomain

@Suite struct SettingsTranslationModelTests {
    @Test func defaultsToOpenAI() {
        #expect(Settings.default.translationModel == .openAIRealtime)
    }

    @Test func roundTripsThroughCodable() throws {
        var s = Settings.default
        s.translationModel = .geminiLiveTranslate
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Settings.self, from: data)
        #expect(back.translationModel == .geminiLiveTranslate)
    }

    @Test func legacyBlobWithoutFieldDecodesToOpenAI() throws {
        // A persisted blob from before this field existed.
        let legacy = """
        {"sessionMode":"call","languagePair":{"mine":"ru","peer":"en"},
         "excludedTapBundleIDs":[],"includedTapBundleIDs":[],
         "tapScopeMode":"allExcept","originalMixVolume":0.2}
        """
        let s = try JSONDecoder().decode(Settings.self, from: Data(legacy.utf8))
        #expect(s.translationModel == .openAIRealtime)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonDomainTests.SettingsTranslationModelTests`
Expected: FAIL — `value of type 'Settings' has no member 'translationModel'`.

- [ ] **Step 3: Add the field**

In `Sources/UnisonDomain/Settings.swift`:
- Add stored property after `tapScopeMode`: `public var translationModel: TranslationModel`.
- Add `translationModel: TranslationModel = .openAIRealtime` to the memberwise `init(...)` params and assign `self.translationModel = translationModel`.
- Add `case translationModel` to `CodingKeys`.
- In `init(from:)` add (after `tapScopeMode` decode):
  ```swift
  self.translationModel = try c.decodeIfPresent(TranslationModel.self,
                                                forKey: .translationModel) ?? .openAIRealtime
  ```
  (Default-on-absent mirrors the existing `includedTapBundleIDs` / `tapScopeMode` decode — backward compatible with old blobs.)

- [ ] **Step 4: Run, verify pass**

Run: `swift build && swift test --filter UnisonDomainTests.SettingsTranslationModelTests`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint
git add Sources/UnisonDomain/Settings.swift Tests/UnisonDomainTests/SettingsTests.swift
git commit -m "feat(domain): persist selected translationModel in Settings"
```

---

## Task 4: Parameterize the input wire sample rate

**Files:**
- Modify: `Sources/UnisonDomain/Protocols/TranslationStream.swift`
- Modify: `Sources/UnisonDomain/Protocols/AudioFormatTransformer.swift`
- Modify: `Sources/UnisonAudio/Resampler.swift`
- Modify: `Sources/UnisonAudio/ResamplerAdapter.swift`
- Modify: `Sources/UnisonDomain/TranslationOrchestrator.swift` (lines ~1500, ~1622)
- Test: `Tests/UnisonAudioTests/ResamplerTests.swift` (extend — check existing name with `ls Tests/UnisonAudioTests/`)

- [ ] **Step 1: Write failing tests for `toWire` at 16 kHz + 24 kHz regression**

Add to the resampler test file (e.g. `Tests/UnisonAudioTests/ResamplerTests.swift`):

```swift
@Test func toWireProduces16kInt16ForGemini() {
    // 48 kHz F32 mono, 100 ms = 4800 samples.
    let samples = [Float](repeating: 0.1, count: 4800)
    let pcm = samples.withUnsafeBytes { Data($0) }
    let frame = AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32)
    let wire = Resampler.toWire(frame, targetSampleRate: 16_000)
    #expect(wire.sampleRate == 16_000)
    #expect(wire.format == .int16)
    // 100 ms at 16 kHz int16 mono ≈ 1600 samples * 2 bytes.
    #expect(abs(wire.pcm.count - 3200) <= 4)
}

@Test func toWire24kMatchesLegacyOpenAIWire() {
    let samples = [Float](repeating: 0.2, count: 4800)
    let pcm = samples.withUnsafeBytes { Data($0) }
    let frame = AudioFrame(pcm: pcm, sampleRate: 48_000, channels: 1, format: .float32)
    let wire = Resampler.toWire(frame, targetSampleRate: 24_000)
    #expect(wire.sampleRate == 24_000)
    #expect(wire.format == .int16)
    #expect(abs(wire.pcm.count - 4800) <= 4) // 2400 samples * 2 bytes
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonAudioTests`
Expected: FAIL — `type 'Resampler' has no member 'toWire'`.

- [ ] **Step 3: Generalize the Resampler**

In `Sources/UnisonAudio/Resampler.swift`, rename + generalize:

```swift
    public static func toWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        if frame.sampleRate == targetSampleRate, frame.format == .int16, frame.channels == 1 { return frame }
        let f32 = frame.format == .float32 ? frame : convertInt16ToFloat32(frame)
        let f32t = resampleFloat32(mixdownToMono(f32), targetSampleRate: targetSampleRate)
        return convertFloat32ToInt16(f32t)
    }

    public static func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        let f32 = frame.format == .float32 ? frame : convertInt16ToFloat32(frame)
        return resampleFloat32(mixdownToMono(f32), targetSampleRate: targetSampleRate)
    }
```

(Delete the old `toOpenAIWire` / `fromOpenAIWire`; `toWire(_, 24_000)` reproduces `toOpenAIWire` exactly.)

- [ ] **Step 4: Update `AudioFormatTransformer` + adapter**

`Sources/UnisonDomain/Protocols/AudioFormatTransformer.swift`:

```swift
public protocol AudioFormatTransformer: Sendable {
    /// Capture format (e.g. 48kHz F32) → wire format (`sampleRate` Int16).
    func toWire(_ frame: AudioFrame, sampleRate: Int) -> AudioFrame
    /// Wire format → playback format (e.g. 48kHz F32) for AVAudioEngine.
    func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame
}
```

`Sources/UnisonAudio/ResamplerAdapter.swift` — update the two methods to forward:

```swift
    public func toWire(_ frame: AudioFrame, sampleRate: Int) -> AudioFrame {
        Resampler.toWire(frame, targetSampleRate: sampleRate)
    }
    public func fromWire(_ frame: AudioFrame, targetSampleRate: Int) -> AudioFrame {
        Resampler.fromWire(frame, targetSampleRate: targetSampleRate)
    }
```

- [ ] **Step 5: Add `inputWireSampleRate` to the stream protocol (with default)**

`Sources/UnisonDomain/Protocols/TranslationStream.swift` — add the requirement and a default so existing conformances (OpenAI stream, all test mocks) need no change:

```swift
public protocol TranslationStream: Sendable {
    var transcripts: AsyncStream<TranscriptDelta> { get }
    var output: AsyncStream<AudioFrame> { get }
    var connectionState: AsyncStream<ConnectionState> { get }

    /// PCM sample rate the engine expects in `send(_:)`. Default 24 kHz
    /// (OpenAI). Gemini overrides to 16 kHz.
    var inputWireSampleRate: Int { get }

    func connect(target: Language) async throws
    func send(_ frame: AudioFrame) async
    func close() async
}

public extension TranslationStream {
    var inputWireSampleRate: Int { 24_000 }
}
```

- [ ] **Step 6: Update the orchestrator's two `toWire` call sites**

In `Sources/UnisonDomain/TranslationOrchestrator.swift`:
- In `wireOutgoingPipeline` (≈ line 1500) read the rate once before the `for await` loop in `task1` and use it:
  ```swift
  let wireRate = stream.inputWireSampleRate
  // … inside the loop:
  let wire = transformer.toWire(frame, sampleRate: wireRate)
  ```
- In `wireIncomingPipeline` (≈ line 1622), inside the `sender` task, capture & use the rate:
  ```swift
  let sender = Task { [stream] in
      let wireRate = stream.inputWireSampleRate
      for await frame in translationFrames {
          let wire = transformer.toWire(frame, sampleRate: wireRate)
          WireDumper.sent.write(wire.pcm)
          await stream.send(wire)
      }
  }
  ```
  (For OpenAI, `wireRate == 24_000` → identical to the old behavior. `fromWire(…, 48_000)` sites are unchanged.)

- [ ] **Step 7: Run full build + tests, verify pass**

Run: `swift build && swift test`
Expected: PASS — all existing pacing/resampler/orchestrator tests still green (OpenAI path byte-identical), plus the two new Resampler tests.

- [ ] **Step 8: Lint + commit**

```bash
swiftlint
git add Sources/UnisonDomain/Protocols/TranslationStream.swift Sources/UnisonDomain/Protocols/AudioFormatTransformer.swift Sources/UnisonAudio/Resampler.swift Sources/UnisonAudio/ResamplerAdapter.swift Sources/UnisonDomain/TranslationOrchestrator.swift Tests/UnisonAudioTests/ResamplerTests.swift
git commit -m "feat(audio): parameterize input wire sample rate per engine (24k/16k)"
```

---

## Task 5: Parameterize Keychain by `TranslationModel`

**Files:**
- Modify: `Sources/UnisonDomain/Protocols/KeychainService.swift`
- Modify: `Sources/UnisonSystem/MacKeychain.swift`
- Modify: `Sources/UnisonApp/Composition.swift` (in-memory stub ~481-483; `apiKeyProvider` ~119-126)
- Modify: `Sources/UnisonApp/DiagnosticCollector.swift:49`
- Modify: `Sources/UnisonUI/ViewModels/SettingsViewModel.swift` (121, 233, 237)
- Modify: `Sources/UnisonUI/ViewModels/OnboardingViewModel.swift` (138, 335)
- Test: `Tests/UnisonSystemTests/MacKeychainTests.swift` (extend — check existing tests first)

This is one atomic signature change (build stays green only when all sites update together). UI VMs pass `.openAIRealtime` for now — Tasks 9-10 make them model-aware.

- [ ] **Step 1: Write failing test for independent per-model slots**

Add to `Tests/UnisonSystemTests/MacKeychainTests.swift`:

```swift
@Test func storesKeysPerModelIndependently() throws {
    let kc = MacKeychain(service: "com.unison.test.\(UUID().uuidString)")
    try? kc.deleteAPIKey(for: .openAIRealtime)
    try? kc.deleteAPIKey(for: .geminiLiveTranslate)

    try kc.saveAPIKey("sk-openai-123", for: .openAIRealtime)
    try kc.saveAPIKey("AQ.gemini-456", for: .geminiLiveTranslate)

    #expect(kc.loadAPIKey(for: .openAIRealtime) == "sk-openai-123")
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.gemini-456")

    // Overwriting one leaves the other intact.
    try kc.saveAPIKey("sk-openai-789", for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.gemini-456")

    try kc.deleteAPIKey(for: .openAIRealtime)
    #expect(kc.loadAPIKey(for: .openAIRealtime) == nil)
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.gemini-456")
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonSystemTests`
Expected: FAIL — `extra argument 'for' in call`.

- [ ] **Step 3: Change the protocol**

`Sources/UnisonDomain/Protocols/KeychainService.swift`:

```swift
public protocol KeychainService: Sendable {
    func loadAPIKey(for model: TranslationModel) -> String?
    func saveAPIKey(_ key: String, for model: TranslationModel) throws
    func deleteAPIKey(for model: TranslationModel) throws
}
```

- [ ] **Step 4: Update `MacKeychain`**

`Sources/UnisonSystem/MacKeychain.swift` — drop the fixed `account` stored property; keep `service` (default `"com.unison.app"`); the account is now `model.keychainAccount` per call. Each method builds its query with `kSecAttrAccount as String: model.keychainAccount`. Update the `init` to `public init(service: String = "com.unison.app")`. Keep the existing error logging. Example for load:

```swift
public func loadAPIKey(for model: TranslationModel) -> String? {
    let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: model.keychainAccount,
        kSecReturnData as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data,
          let str = String(data: data, encoding: .utf8) else { return nil }
    return str
}
```

Mirror the same `model.keychainAccount` substitution in `saveAPIKey`/`deleteAPIKey` (keep their existing add/update/delete branching).

- [ ] **Step 5: Update the in-memory stub in Composition**

`Sources/UnisonApp/Composition.swift` (~481): make it a per-model dict so harness mode can seed either engine:

```swift
final class InMemoryKeychain: KeychainService, @unchecked Sendable {
    private var keys: [TranslationModel: String]
    init(seed: String? = nil) {
        // Seed BOTH slots so any selected model resolves in harness mode.
        keys = seed.map { s in [.openAIRealtime: s, .geminiLiveTranslate: s] } ?? [:]
    }
    func loadAPIKey(for model: TranslationModel) -> String? { keys[model] }
    func saveAPIKey(_ key: String, for model: TranslationModel) throws { keys[model] = key }
    func deleteAPIKey(for model: TranslationModel) throws { keys[model] = nil }
}
```

(Match the existing type name/shape — if the current stub is named differently, keep its name and just adapt the methods + storage.)

- [ ] **Step 6: Update remaining call sites (pass `.openAIRealtime` for now)**

- `Composition.swift` `apiKeyProvider` (~125): `let stored = kc.loadAPIKey(for: .openAIRealtime) ?? ""` (Task 8 makes it model-aware).
- `DiagnosticCollector.swift:49`: `if let k = composition.keychain.loadAPIKey(for: .openAIRealtime), !k.isEmpty {`
- `SettingsViewModel.swift:121`: `self.apiKey = keychain?.loadAPIKey(for: .openAIRealtime) ?? ""`
- `SettingsViewModel.swift:233/237`: `keychain.deleteAPIKey(for: .openAIRealtime)` / `keychain.saveAPIKey(trimmed, for: .openAIRealtime)`
- `OnboardingViewModel.swift:138`: `let keyDone = keychain.loadAPIKey(for: .openAIRealtime)?.isEmpty == false`
- `OnboardingViewModel.swift:335`: `try keychain.saveAPIKey(trimmed, for: .openAIRealtime)`

- [ ] **Step 7: Run full build + tests, verify pass**

Run: `swift build && swift test`
Expected: PASS (behavior unchanged — everything still uses the OpenAI slot).

- [ ] **Step 8: Lint + commit**

```bash
swiftlint
git add -A
git commit -m "feat(domain): parameterize KeychainService by TranslationModel (two slots)"
```

---

## Task 6: Gemini Live API JSON envelopes (`GeminiEvents.swift`)

**Files:**
- Create: `Sources/UnisonTranslation/GeminiEvents.swift`
- Test: `Tests/UnisonTranslationTests/GeminiEventsTests.swift`

Mirror the idiom in `Sources/UnisonTranslation/RealtimeEvents.swift` (enum + per-payload `encodeWrapped`, custom `Decodable`). Foundation-touching test helpers go via `Helpers.swift` (the test file uses `import Testing` only).

- [ ] **Step 1: Write failing tests**

Create `Tests/UnisonTranslationTests/GeminiEventsTests.swift`:

```swift
import Testing
@testable import UnisonTranslation

@Suite struct GeminiEventsTests {
    @Test func setupEncodesModelAndTargetLanguage() throws {
        let evt = GeminiClientEvent.setup(.init(targetLanguage: "ru"))
        let json = try encodeToJSONString(evt)
        #expect(json.contains("\"setup\""))
        #expect(json.contains("models/gemini-3.5-live-translate-preview"))
        #expect(json.contains("\"targetLanguageCode\":\"ru\""))
        #expect(json.contains("\"responseModalities\":[\"AUDIO\"]"))
        #expect(json.contains("inputAudioTranscription"))
        #expect(json.contains("outputAudioTranscription"))
    }

    @Test func realtimeAudioEncodes16kMime() throws {
        let evt = GeminiClientEvent.realtimeAudio(base64: "QUJD")
        let json = try encodeToJSONString(evt)
        #expect(json.contains("\"realtimeInput\""))
        #expect(json.contains("\"data\":\"QUJD\""))
        #expect(json.contains("audio/pcm;rate=16000"))
    }

    @Test func decodesAudioInlineData() throws {
        let json = """
        {"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}
        """
        let evt = try decodeGeminiServerEvent(json)
        guard case .audio(let b64) = evt else { Issue.record("expected .audio"); return }
        #expect(b64 == "QUJD")
    }

    @Test func decodesInputAndOutputTranscription() throws {
        let inJSON = #"{"serverContent":{"inputTranscription":{"text":"привет"}}}"#
        let outJSON = #"{"serverContent":{"outputTranscription":{"text":"hello"}}}"#
        guard case .inputTranscript(let i) = try decodeGeminiServerEvent(inJSON) else {
            Issue.record("expected input"); return
        }
        guard case .outputTranscript(let o) = try decodeGeminiServerEvent(outJSON) else {
            Issue.record("expected output"); return
        }
        #expect(i == "привет")
        #expect(o == "hello")
    }

    @Test func decodesTurnCompleteAndSetupComplete() throws {
        guard case .turnComplete = try decodeGeminiServerEvent(#"{"serverContent":{"turnComplete":true}}"#) else {
            Issue.record("expected turnComplete"); return
        }
        guard case .setupComplete = try decodeGeminiServerEvent(#"{"setupComplete":{}}"#) else {
            Issue.record("expected setupComplete"); return
        }
    }
}
```

Add these helpers to `Tests/UnisonTranslationTests/Helpers.swift`:

```swift
func decodeGeminiServerEvent(_ json: String) throws -> GeminiServerEvent {
    let data = json.data(using: .utf8)!
    return try JSONDecoder().decode(GeminiServerEvent.self, from: data)
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonTranslationTests.GeminiEventsTests`
Expected: FAIL — `cannot find 'GeminiClientEvent' in scope`.

- [ ] **Step 3: Implement the envelopes**

Create `Sources/UnisonTranslation/GeminiEvents.swift`:

```swift
import Foundation

/// Client → server messages for the Gemini Live API (raw WebSocket JSON).
/// Shapes per https://ai.google.dev/gemini-api/docs/live-api .
public enum GeminiClientEvent: Encodable, Sendable {
    case setup(GeminiSetupPayload)
    case realtimeAudio(base64: String)

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .setup(let p):
            try p.encode(to: encoder)
        case .realtimeAudio(let b64):
            struct Audio: Encodable { let data: String; let mimeType: String }
            struct RealtimeInput: Encodable { let audio: Audio }
            struct Envelope: Encodable { let realtimeInput: RealtimeInput }
            try Envelope(realtimeInput: .init(
                audio: .init(data: b64, mimeType: "audio/pcm;rate=16000")
            )).encode(to: encoder)
        }
    }
}

public struct GeminiSetupPayload: Sendable {
    public let targetLanguage: String
    public init(targetLanguage: String) { self.targetLanguage = targetLanguage }

    func encode(to encoder: Encoder) throws {
        struct TranslationConfig: Encodable { let targetLanguageCode: String }
        struct Empty: Encodable {}
        struct GenerationConfig: Encodable {
            let responseModalities: [String]
            let inputAudioTranscription: Empty
            let outputAudioTranscription: Empty
            let translationConfig: TranslationConfig
        }
        struct Setup: Encodable { let model: String; let generationConfig: GenerationConfig }
        struct Envelope: Encodable { let setup: Setup }
        try Envelope(setup: .init(
            model: "models/gemini-3.5-live-translate-preview",
            generationConfig: .init(
                responseModalities: ["AUDIO"],
                inputAudioTranscription: .init(),
                outputAudioTranscription: .init(),
                translationConfig: .init(targetLanguageCode: targetLanguage)
            )
        )).encode(to: encoder)
    }
}

/// Server → client messages we act on. Everything else → `.unknown`.
public enum GeminiServerEvent: Sendable {
    case setupComplete
    case audio(base64: String)         // 24 kHz int16 PCM
    case inputTranscript(String)        // source-language text
    case outputTranscript(String)       // translated text
    case turnComplete
    case goAway
    case unknown
}

extension GeminiServerEvent: Decodable {
    private enum Top: String, CodingKey { case serverContent, setupComplete, goAway }
    private enum Content: String, CodingKey {
        case modelTurn, inputTranscription, outputTranscription, turnComplete
    }
    private enum Turn: String, CodingKey { case parts }
    private enum Part: String, CodingKey { case inlineData }
    private enum Inline: String, CodingKey { case data, mimeType }
    private enum Text: String, CodingKey { case text }

    public init(from decoder: Decoder) throws {
        let top = try decoder.container(keyedBy: Top.self)
        if top.contains(.setupComplete) { self = .setupComplete; return }
        if top.contains(.goAway) { self = .goAway; return }
        guard top.contains(.serverContent) else { self = .unknown; return }
        let content = try top.nestedContainer(keyedBy: Content.self, forKey: .serverContent)

        // Audio in the first inlineData part of the model turn.
        if let turn = try? content.nestedContainer(keyedBy: Turn.self, forKey: .modelTurn),
           var parts = try? turn.nestedUnkeyedContainer(forKey: .parts) {
            while !parts.isAtEnd {
                let part = try parts.nestedContainer(keyedBy: Part.self)
                if let inline = try? part.nestedContainer(keyedBy: Inline.self, forKey: .inlineData),
                   let data = try? inline.decode(String.self, forKey: .data) {
                    self = .audio(base64: data); return
                }
            }
        }
        if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .inputTranscription),
           let text = try? t.decode(String.self, forKey: .text) {
            self = .inputTranscript(text); return
        }
        if let t = try? content.nestedContainer(keyedBy: Text.self, forKey: .outputTranscription),
           let text = try? t.decode(String.self, forKey: .text) {
            self = .outputTranscript(text); return
        }
        if (try? content.decode(Bool.self, forKey: .turnComplete)) == true {
            self = .turnComplete; return
        }
        self = .unknown
    }
}
```

- [ ] **Step 4: Run, verify pass**

Run: `swift build && swift test --filter UnisonTranslationTests.GeminiEventsTests`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint
git add Sources/UnisonTranslation/GeminiEvents.swift Tests/UnisonTranslationTests/GeminiEventsTests.swift Tests/UnisonTranslationTests/Helpers.swift
git commit -m "feat(translation): add Gemini Live API JSON envelopes"
```

---

## Task 7: `GeminiLiveTranslateStream` actor

**Files:**
- Create: `Sources/UnisonTranslation/GeminiLiveTranslateStream.swift`
- Test: `Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift`

Mirror `OpenAIRealtimeStream` (`Sources/UnisonTranslation/OpenAIRealtimeStream.swift`) for the lifecycle boilerplate — the three `nonisolated let` streams + continuations (`:20-29, 146-155`), the `receiveTask`/`closeReasonTask` wiring (`:175-188`), the `close()` grace logic (`:249-288`), and the turn-rotation idea (`rotateOnInputGap`, `:225-238`). Below are the **Gemini-specific** differences; everything else is a direct copy.

- [ ] **Step 1: Write failing tests (FakeWSClient)**

Create `Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift`:

```swift
import Testing
@testable import UnisonTranslation
import UnisonDomain

@Suite struct GeminiLiveTranslateStreamTests {
    @Test func connectSendsSetupWithKeyInQueryAndTarget() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.test-key", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .ru)

        // Key travels in the URL query, NOT a header.
        let (url, headers) = ws.connectCalls[0]
        #expect(url.absoluteString.contains("key=AQ.test-key"))
        #expect(headers["Authorization"] == nil)

        let setup = ws.sentMessages.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.first
        #expect(setup?.contains("gemini-3.5-live-translate-preview") == true)
        #expect(setup?.contains("\"targetLanguageCode\":\"ru\"") == true)
    }

    @Test func inputWireSampleRateIs16k() {
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: FakeWSClient(), clock: SystemClock(), speaker: .me)
        #expect(stream.inputWireSampleRate == 16_000)
    }

    @Test func sendEncodesRealtimeAudio() async {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .me)
        await stream.send(AudioFrame(pcm: Data([1, 2, 3, 4]), sampleRate: 16_000, channels: 1, format: .int16))
        let msg = ws.sentMessages.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.last
        #expect(msg?.contains("realtimeInput") == true)
        #expect(msg?.contains("audio/pcm;rate=16000") == true)
    }

    @Test func audioDeltaYieldsFrameAt24k() async throws {
        let ws = FakeWSClient()
        let stream = GeminiLiveTranslateStream(
            apiKey: "AQ.k", client: ws, clock: SystemClock(), speaker: .peer)
        try await stream.connect(target: .en)
        ws.push(.text(#"{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"data":"QUJD","mimeType":"audio/pcm;rate=24000"}}]}}}"#))

        var iterator = stream.output.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame?.sampleRate == 24_000)
        #expect(frame?.format == .int16)
    }

    @Test func preDataNormalCloseClassifiesAsApiKeyInvalid() {
        // Mirror OpenAI: handshake ok then a normal close before any data
        // is the auth-rejection signature.
        let mapped = GeminiLiveTranslateStream.classifyClose(
            code: 1008, reason: nil, receivedData: false)
        #expect(mapped == .apiKeyInvalid)
    }
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonTranslationTests.GeminiLiveTranslateStreamTests`
Expected: FAIL — `cannot find 'GeminiLiveTranslateStream' in scope`.

- [ ] **Step 3: Implement the actor**

Create `Sources/UnisonTranslation/GeminiLiveTranslateStream.swift`. Copy the OpenAI stream's structure; the differences:

```swift
import Foundation
import UnisonDomain

public actor GeminiLiveTranslateStream: TranslationStream {
    private static let log = UnisonLog(category: "GeminiLiveTranslateStream")
    private static let base =
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    private let apiKey: String
    private let client: any WSClient
    private let clock: any Clock
    private let speaker: Speaker

    public nonisolated let transcripts: AsyncStream<TranscriptDelta>
    public nonisolated let output: AsyncStream<AudioFrame>
    public nonisolated let connectionState: AsyncStream<ConnectionState>
    private nonisolated let transcriptContinuation: AsyncStream<TranscriptDelta>.Continuation
    private nonisolated let outputContinuation: AsyncStream<AudioFrame>.Continuation
    private nonisolated let connectionContinuation: AsyncStream<ConnectionState>.Continuation

    // Gemini expects 16 kHz input (output is 24 kHz like OpenAI).
    public nonisolated let inputWireSampleRate: Int = 16_000

    private var receiveTask: Task<Void, Never>?
    private var closeReasonTask: Task<Void, Never>?
    private var currentEntryId = UUID()
    private var lastInputDeltaAt: Date?
    private static let turnGapSeconds: TimeInterval = 5.0
    private var receivedAnyData = false
    private var lastClassifiedError: TranslationError?
    private var closeStarted = false

    public init(apiKey: String, client: any WSClient, clock: any Clock, speaker: Speaker = .peer) {
        self.apiKey = apiKey
        self.client = client
        self.clock = clock
        self.speaker = speaker
        var tc: AsyncStream<TranscriptDelta>.Continuation!
        var oc: AsyncStream<AudioFrame>.Continuation!
        var cc: AsyncStream<ConnectionState>.Continuation!
        self.transcripts = AsyncStream { tc = $0 }
        self.output = AsyncStream { oc = $0 }
        self.connectionState = AsyncStream { cc = $0 }
        self.transcriptContinuation = tc
        self.outputContinuation = oc
        self.connectionContinuation = cc
    }

    public func connect(target: Language) async throws {
        connectionContinuation.yield(.connecting)
        // Key in the query param (percent-encoded). NEVER log this URL.
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) ?? apiKey
        guard let url = URL(string: "\(Self.base)?key=\(encodedKey)") else {
            throw TranslationError.networkLost
        }
        try await client.connect(url: url, headers: [:])   // no auth header
        connectionContinuation.yield(.connected)

        let stream = client.receive()
        receiveTask = Task { [weak self] in
            for await msg in stream { await self?.handle(message: msg) }
        }
        let closeSource = client.closeStream()
        closeReasonTask = Task { [weak self] in
            for await reason in closeSource { await self?.handleClose(reason: reason) }
        }

        let evt = GeminiClientEvent.setup(.init(targetLanguage: target.rawValue))
        let data = try JSONEncoder().encode(evt)
        try await client.send(.text(String(data: data, encoding: .utf8) ?? ""))
    }

    public func send(_ frame: AudioFrame) async {
        let evt = GeminiClientEvent.realtimeAudio(base64: frame.pcm.base64EncodedString())
        guard let data = try? JSONEncoder().encode(evt),
              let str = String(data: data, encoding: .utf8) else { return }
        try? await client.send(.text(str))
    }

    public func close() async {
        guard !closeStarted else { return }
        closeStarted = true
        receiveTask?.cancel()
        closeReasonTask?.cancel()
        await client.close()
        connectionContinuation.yield(.disconnected)
        transcriptContinuation.finish()
        outputContinuation.finish()
        connectionContinuation.finish()
    }

    private func setClassifiedError(_ e: TranslationError) {
        if lastClassifiedError == nil { lastClassifiedError = e }
    }

    private func rotateOnInputGap() {
        let now = clock.now()
        if let prev = lastInputDeltaAt, now.timeIntervalSince(prev) >= Self.turnGapSeconds {
            currentEntryId = UUID()
        }
        lastInputDeltaAt = now
    }

    private func handle(message: WSMessage) async {
        guard case .text(let str) = message,
              let data = str.data(using: .utf8),
              let event = try? JSONDecoder().decode(GeminiServerEvent.self, from: data) else { return }
        switch event {
        case .setupComplete:
            break
        case .audio(let b64):
            guard let pcm = Data(base64Encoded: b64) else { return }
            receivedAnyData = true
            outputContinuation.yield(AudioFrame(pcm: pcm, sampleRate: 24_000, channels: 1, format: .int16))
        case .inputTranscript(let text):
            rotateOnInputGap()
            receivedAnyData = true
            transcriptContinuation.yield(TranscriptDelta(
                entryId: currentEntryId, speaker: speaker, kind: .original, text: text, isFinal: false))
        case .outputTranscript(let text):
            receivedAnyData = true
            transcriptContinuation.yield(TranscriptDelta(
                entryId: currentEntryId, speaker: speaker, kind: .translated, text: text, isFinal: false))
        case .turnComplete:
            currentEntryId = UUID()
            lastInputDeltaAt = nil
        case .goAway:
            Self.log.info("\(String(describing: speaker)) goAway — server will close soon")
        case .unknown:
            break
        }
    }

    private func handleClose(reason: WSCloseReason) {
        let receivedData = receivedAnyData
        switch reason {
        case .normal:
            if receivedData {
                connectionContinuation.yield(.disconnected)
            } else {
                setClassifiedError(.apiKeyInvalid)
                connectionContinuation.yield(.failed(.apiKeyInvalid, receivedAnyData: false))
            }
        case .abnormal(let code, let reasonText):
            let mapped = Self.classifyClose(code: code, reason: reasonText, receivedData: receivedData)
            setClassifiedError(mapped)
            connectionContinuation.yield(.failed(mapped, receivedAnyData: receivedData))
        case .error:
            setClassifiedError(.networkLost)
            connectionContinuation.yield(.failed(.networkLost, receivedAnyData: receivedData))
        }
    }

    /// Map a WS close code / reason to a TranslationError. Gemini puts
    /// HTTP-style auth failures (401/403) into the close payload; quota →
    /// 429. Pre-data close ⇒ auth (handshake ok, then dropped).
    static func classifyClose(code: Int, reason: String?, receivedData: Bool) -> TranslationError {
        if let r = reason?.lowercased(), !r.isEmpty {
            if r.contains("api key") || r.contains("api_key") || r.contains("unauthenticated")
                || r.contains("permission") || r.contains("401") || r.contains("403") {
                return .apiKeyInvalid
            }
            if r.contains("quota") || r.contains("resource_exhausted") || r.contains("billing") {
                return .insufficientCredits
            }
            if r.contains("rate") || r.contains("429") { return .rateLimited(retryAfter: 5) }
        }
        switch code {
        case 1008: return .apiKeyInvalid
        case 1011: return receivedData ? .networkLost : .apiKeyInvalid
        default:   return .networkLost
        }
    }
}
```

> Verify `TranslationError` cases (`apiKeyInvalid`, `insufficientCredits`, `rateLimited(retryAfter:)`, `networkLost`), `Speaker`, `TranscriptDelta.init`, and `UnisonLog`/`Clock`/`SystemClock` names against `OpenAIRealtimeStream.swift` while copying. If Gemini's translation transcript should land as `.original` vs `.translated`, match the OpenAI mapping (input→`.original`, output→`.translated`).

- [ ] **Step 4: Run, verify pass**

Run: `swift build && swift test --filter UnisonTranslationTests.GeminiLiveTranslateStreamTests`
Expected: PASS.

- [ ] **Step 5: Lint + commit**

```bash
swiftlint
git add Sources/UnisonTranslation/GeminiLiveTranslateStream.swift Tests/UnisonTranslationTests/GeminiLiveTranslateStreamTests.swift
git commit -m "feat(translation): add GeminiLiveTranslateStream"
```

---

## Task 8: Provider-aware factory in Composition

**Files:**
- Modify: `Sources/UnisonApp/Composition.swift` (factory ~502-513; apiKeyProvider ~119-126)
- Test: covered by existing orchestrator tests + manual verification (factory wiring is host glue).

- [ ] **Step 1: Replace the factory**

In `Sources/UnisonApp/Composition.swift`, replace `OpenAIRealtimeStreamFactory` with:

```swift
final class ProviderAwareStreamFactory: TranslationStreamFactory, @unchecked Sendable {
    private let modelProvider: () -> TranslationModel
    private let apiKeyProvider: (TranslationModel) -> String
    private let clock: any Clock

    init(modelProvider: @escaping () -> TranslationModel,
         apiKeyProvider: @escaping (TranslationModel) -> String,
         clock: any Clock) {
        self.modelProvider = modelProvider
        self.apiKeyProvider = apiKeyProvider
        self.clock = clock
    }

    func make(speaker: Speaker) -> any TranslationStream {
        let model = modelProvider()
        let key = apiKeyProvider(model)
        switch model {
        case .openAIRealtime:
            return OpenAIRealtimeStream(apiKey: key, client: URLSessionWSClient(), clock: clock, speaker: speaker)
        case .geminiLiveTranslate:
            return GeminiLiveTranslateStream(apiKey: key, client: URLSessionWSClient(), clock: clock, speaker: speaker)
        }
    }
}
```

- [ ] **Step 2: Wire it where the old factory was constructed (~119)**

Replace the `OpenAIRealtimeStreamFactory(apiKeyProvider:clock:)` construction with:

```swift
let kc = self.keychain
let store = self.settingsStore   // same store used elsewhere in Composition
let factory = ProviderAwareStreamFactory(
    modelProvider: { store.load().translationModel },
    apiKeyProvider: { model in
        // Env overrides for harness/dev: per-engine.
        let env = ProcessInfo.processInfo.environment
        switch model {
        case .openAIRealtime:
            if let k = env["UNISON_API_KEY"], !k.isEmpty { return k }
        case .geminiLiveTranslate:
            if let k = env["UNISON_GEMINI_API_KEY"], !k.isEmpty { return k }
        }
        let stored = kc.loadAPIKey(for: model) ?? ""
        Self.bootLog.info("apiKey source=keychain model=\(model.rawValue) length=\(stored.count) prefix=\(Self.apiKeyPrefix(stored))")
        return stored
    },
    clock: clock
)
```

(Use the existing `clock` value passed to the orchestrator, and the existing `settingsStore` reference. Keep the existing `Self.bootLog` / `Self.apiKeyPrefix` helpers.)

- [ ] **Step 3: Build + full test suite**

Run: `swift build && swift test`
Expected: PASS (orchestrator tests use their own mock factory; this is host wiring).

- [ ] **Step 4: Lint + commit**

```bash
swiftlint
git add Sources/UnisonApp/Composition.swift
git commit -m "feat(app): provider-aware translation stream factory + per-engine key resolution"
```

---

## Task 9: Settings UI — model picker + model-aware key + per-model languages

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/SettingsViewModel.swift`
- Modify: `Sources/UnisonUI/Views/SettingsView.swift`
- Modify: `Sources/UnisonUI/Views/PopoverView.swift` (language picker source)
- Test: `Tests/UnisonUITests/SettingsViewModelTests.swift` (extend/create)

- [ ] **Step 1: Write failing VM tests**

Add to a UI VM test file:

```swift
@MainActor @Test func switchingModelCoercesUnsupportedLanguages() {
    var saved: Settings?
    let vm = SettingsViewModel(
        initial: { var s = Settings.default; s.translationModel = .geminiLiveTranslate
                   s.languagePair = LanguagePair(mine: .pl, peer: .en); return s }(),
        deviceRegistry: StubDeviceRegistry(),         // existing test double
        onChange: { saved = $0 })
    vm.setTranslationModel(.openAIRealtime)
    #expect(vm.settings.translationModel == .openAIRealtime)
    // Polish isn't an OpenAI target → must be coerced away.
    #expect(TranslationModel.openAIRealtime.supportedTargets.contains(vm.settings.languagePair.mine))
    #expect(saved?.translationModel == .openAIRealtime)
}

@MainActor @Test func keyFieldReloadsForSelectedModel() {
    let kc = InMemoryKeychain()
    try? kc.saveAPIKey("sk-aaa", for: .openAIRealtime)
    try? kc.saveAPIKey("AQ.bbb", for: .geminiLiveTranslate)
    let vm = SettingsViewModel(initial: .default, deviceRegistry: StubDeviceRegistry(),
                               onChange: { _ in }, keychain: kc)
    #expect(vm.apiKey == "sk-aaa")             // default model = OpenAI
    vm.setTranslationModel(.geminiLiveTranslate)
    #expect(vm.apiKey == "AQ.bbb")             // reloaded for Gemini slot
}
```

(`InMemoryKeychain` must be visible to tests — if it's `internal` in `UnisonApp`, add a small public test double in the test target instead, conforming to `KeychainService`.)

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonUITests`
Expected: FAIL — `value of type 'SettingsViewModel' has no member 'setTranslationModel'`.

- [ ] **Step 3: Add VM model state**

In `SettingsViewModel.swift`:
- Make `apiKey` reload track the selected model. Change the init seed (line 121) to:
  ```swift
  self.apiKey = keychain?.loadAPIKey(for: initial.translationModel) ?? ""
  ```
- Add:
  ```swift
  public func setTranslationModel(_ model: TranslationModel) {
      settings.translationModel = model
      settings.languagePair = model.coerced(settings.languagePair)
      // Reload the key field for the newly-selected engine's slot.
      apiKey = keychain?.loadAPIKey(for: model) ?? ""
      emitChange()
  }
  ```
- Make `updateApiKey` model-aware (replace the hardcoded `.openAIRealtime` from Task 5 and the `sk-` check with the model's accepted prefixes):
  ```swift
  public func updateApiKey(_ key: String) {
      apiKey = key
      guard let keychain else { bumpSavedTimestamp(); return }
      let model = settings.translationModel
      let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
          if (try? keychain.deleteAPIKey(for: model)) != nil { bumpSavedTimestamp() }
      } else if model.acceptedKeyPrefixes.contains(where: trimmed.hasPrefix), trimmed.count >= 20 {
          if (try? keychain.saveAPIKey(trimmed, for: model)) != nil { bumpSavedTimestamp() }
      }
  }
  ```

- [ ] **Step 4: Run VM tests, verify pass**

Run: `swift test --filter UnisonUITests`
Expected: PASS.

- [ ] **Step 5: Add the «Модель перевода» section + model-driven language picker**

In `SettingsView.swift`, rename `openAISection` → `modelSection` (and update its reference in the section `VStack`). New body:

```swift
private var modelSection: some View {
    card(title: "Модель перевода") {
        LabeledContent("Движок") {
            Picker("Движок", selection: Binding(
                get: { vm.settings.translationModel },
                set: { vm.setTranslationModel($0) }
            )) {
                ForEach(TranslationModel.allCases, id: \.self) { model in
                    Text(model.displayName).tag(model)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
        }

        // API-key field, adapts to the selected engine.
        SecretInput(
            text: Binding(get: { vm.apiKey }, set: { vm.updateApiKey($0) }),
            placeholder: vm.settings.translationModel.apiKeyPlaceholder
        )
        HStack {
            MutedLink("Получить ключ") { openURL(vm.settings.translationModel.getKeyURL) }
            Spacer()
            Text("Keychain").font(.caption).foregroundStyle(.tertiary)
        }
    }
}
```

(Mirror the existing `openAISection` markup for `SecretInput` / `MutedLink` / the "Keychain" caption and the `openURL` mechanism — reuse whatever the old section used; only the binding source and the placeholder/URL become model-driven.)

Update the two language pickers (lines ~229, ~245) to read the model's targets:

```swift
ForEach(vm.settings.translationModel.supportedTargets, id: \.self) { lang in
    Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
}
```

- [ ] **Step 6: Update PopoverView language picker (line ~239)**

In `Sources/UnisonUI/Views/PopoverView.swift`, change the `ForEach(Language.supportedTargets …)` to the selected model's targets (the popover has the `settings` value):

```swift
ForEach(settings.translationModel.supportedTargets, id: \.self) { lang in
    Text("\(lang.flagEmoji) \(lang.displayName)").tag(lang)
}
```

(If the popover view model exposes settings differently, use that accessor — the point is to source the list from `…translationModel.supportedTargets`.)

- [ ] **Step 7: Build + full suite + snapshot refresh if needed**

Run: `swift build && swift test`
Expected: PASS. If a Settings snapshot test fails purely due to the new row, re-record per the repo's snapshot workflow (check `Tests/UnisonUITests/` for the record flag) and eyeball the diff.

- [ ] **Step 8: Lint + commit**

```bash
swiftlint
git add Sources/UnisonUI/ViewModels/SettingsViewModel.swift Sources/UnisonUI/Views/SettingsView.swift Sources/UnisonUI/Views/PopoverView.swift Tests/UnisonUITests
git commit -m "feat(ui): model picker in Settings + per-engine key and languages"
```

---

## Task 10: Onboarding — provider selector + model-aware key

**Files:**
- Modify: `Sources/UnisonUI/ViewModels/OnboardingViewModel.swift`
- Modify: `Sources/UnisonUI/Views/OnboardingView.swift`
- Test: `Tests/UnisonUITests/OnboardingViewModelTests.swift` (extend/create)

- [ ] **Step 1: Write failing VM tests**

```swift
@MainActor @Test func validatesKeyAgainstSelectedModelPrefix() {
    let vm = OnboardingViewModel(keychain: InMemoryKeychain(), /* existing deps */)
    vm.selectedModel = .geminiLiveTranslate
    vm.apiKeyDraft = "AQ.abcdefghij1234567890"
    #expect(vm.canSaveKey)                       // AQ. accepted for Gemini
    vm.apiKeyDraft = "sk-abcdefghij1234567890"
    #expect(!vm.canSaveKey)                       // sk- is not a Gemini key
}

@MainActor @Test func savesKeyToSelectedModelSlot() throws {
    let kc = InMemoryKeychain()
    let vm = OnboardingViewModel(keychain: kc, /* existing deps */)
    vm.selectedModel = .geminiLiveTranslate
    vm.apiKeyDraft = "AQ.abcdefghij1234567890"
    vm.saveAPIKey()
    #expect(kc.loadAPIKey(for: .geminiLiveTranslate) == "AQ.abcdefghij1234567890")
    #expect(kc.loadAPIKey(for: .openAIRealtime) == nil)
}
```

- [ ] **Step 2: Run, verify fail**

Run: `swift test --filter UnisonUITests`
Expected: FAIL — no member `selectedModel`.

- [ ] **Step 3: Make the VM model-aware**

In `OnboardingViewModel.swift`:
- Add `public var selectedModel: TranslationModel = .openAIRealtime`.
- Replace the static `validateAPIKey` hard `sk-` rule with a model-aware instance check (keep a static helper for tests if convenient):
  ```swift
  public nonisolated static func validateAPIKey(_ key: String, for model: TranslationModel) -> Bool {
      let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
      return model.acceptedKeyPrefixes.contains(where: trimmed.hasPrefix) && trimmed.count >= 20
  }
  public var canSaveKey: Bool { Self.validateAPIKey(apiKeyDraft, for: selectedModel) }
  ```
- `saveAPIKey()` (line ~328): validate with `selectedModel`, save with `keychain.saveAPIKey(trimmed, for: selectedModel)`, error copy unchanged. Update the error message to reference the selected engine's expected prefix generically (e.g. «Ключ не похож на ключ выбранного провайдера.»).
- Readiness gate (line ~138): `let keyDone = keychain.loadAPIKey(for: selectedModel)?.isEmpty == false`.

- [ ] **Step 4: Run VM tests, verify pass**

Run: `swift test --filter UnisonUITests`
Expected: PASS.

- [ ] **Step 5: Add the provider selector to the key card**

In `OnboardingView.swift` `apiKeyCard` (≈ 304-357), add a compact provider Picker above the `SecretInput`, and drive placeholder + "Получить ключ" URL from `vm.selectedModel`:

```swift
Picker("Провайдер", selection: Binding(
    get: { vm.selectedModel },
    set: { vm.selectedModel = $0; vm.clearError(for: .apiKey) }
)) {
    ForEach(TranslationModel.allCases, id: \.self) { Text($0.displayName).tag($0) }
}
.pickerStyle(.segmented)
.labelsHidden()
```

- Change the `SecretInput` placeholder to `vm.selectedModel.apiKeyPlaceholder`.
- Change `MutedLink("Получить ключ")` action to `onOpenURL(vm.selectedModel.getKeyURL)`.
- The card title can stay "Ключ API" (generalize from "OpenAI ключ").

- [ ] **Step 6: Build + suite + snapshots**

Run: `swift build && swift test`
Expected: PASS (re-record onboarding snapshot if it changed for the new selector; eyeball diff).

- [ ] **Step 7: Lint + commit**

```bash
swiftlint
git add Sources/UnisonUI/ViewModels/OnboardingViewModel.swift Sources/UnisonUI/Views/OnboardingView.swift Tests/UnisonUITests
git commit -m "feat(ui): engine selector in onboarding + model-aware key validation"
```

---

## Task 11: `pacing-eval --provider` for live verification

**Files:**
- Modify: `Sources/Tools/PacingEval/Session.swift` (~75-83)
- Modify: `Sources/Tools/PacingEval/main.swift` (arg parsing)

- [ ] **Step 1: Add a provider arg + branch the stream construction**

In `main.swift`, parse `--provider openai|gemini` (default `openai`) into the session config. In `Session.swift` (~75), branch:

```swift
let stream: any TranslationStream = provider == .geminiLiveTranslate
    ? GeminiLiveTranslateStream(apiKey: apiKey, client: URLSessionWSClient(), clock: clock, speaker: .peer)
    : OpenAIRealtimeStream(apiKey: apiKey, client: URLSessionWSClient(), clock: clock, speaker: .peer)
try await stream.connect(target: targetLang)
```

(Import `UnisonDomain` for `TranslationModel` if not already; reuse the existing `apiKey`/`targetLang`/`clock` locals. The downstream resample in the eval, if it calls `Resampler.toWire`, must pass `stream.inputWireSampleRate`.)

- [ ] **Step 2: Build the tool**

Run: `swift build --product pacing-eval`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
swiftlint
git add Sources/Tools/PacingEval
git commit -m "feat(tools): pacing-eval --provider for live Gemini verification"
```

---

## Task 12: Documentation

**Files:**
- Modify: `docs/audio-pipeline.md`
- Modify: `README.md`

- [ ] **Step 1: Update `docs/audio-pipeline.md`**

In the model section, note there are now **two** engines behind the same chain: OpenAI `gpt-realtime-translate` (24 kHz input) and Gemini `gemini-3.5-live-translate-preview` (16 kHz input); both output 24 kHz. Document Gemini's endpoint/auth (`?key=`), the `BidiGenerateContentSetup` shape, `translationConfig.targetLanguageCode`, and that the engine is chosen via `Settings.translationModel` and resolved at `start()`.

- [ ] **Step 2: Update `README.md`**

Add the model-selection feature: choose engine in Onboarding/Settings, two API keys (one per engine), Gemini's broader language list. Note the `UNISON_GEMINI_API_KEY` dev override alongside `UNISON_API_KEY`.

- [ ] **Step 3: Commit**

```bash
git add docs/audio-pipeline.md README.md
git commit -m "docs: document Gemini engine option and model selection"
```

---

## Task 13: Full verification

- [ ] **Step 1: Whole suite + lint + build**

Run: `swift build && swift test && swiftlint`
Expected: all green, zero new lint warnings.

- [ ] **Step 2: Live Gemini run against the real API**

```bash
swift run pacing-eval --provider gemini \
  --audio Tests/Fixtures/audio/ru-monologue-normal.wav --target en --runs 1
```
Use the test key (env or keychain): `UNISON_GEMINI_API_KEY=AQ.… swift run pacing-eval --provider gemini …`.
Expected: WS connects to `generativelanguage.googleapis.com`, setup accepted, translated 24 kHz audio + transcripts arrive (non-empty), session closes cleanly. Capture arrival stats. (Confirm no key is printed in logs.)

- [ ] **Step 3: VM screenshots (macOS 26 / Tart)**

Build/sign per `docs/release.md` or the existing screenshot harness; launch with `UNISON_FORCE_STATE=settings-open` and an onboarding force-state. Verify: «Модель перевода» picker switches engine; language list changes (Gemini shows Polish etc.; OpenAI doesn't); onboarding shows the engine selector; placeholder/«Получить ключ» track the selection. Save screenshots under `docs/images/` if that's the repo convention.

- [ ] **Step 4: Manual key round-trip sanity**

In the VM/app: enter a Gemini key, switch engine to OpenAI and back — confirm each engine's key persists in its own slot (re-open Settings; both remembered).

- [ ] **Step 5: Final commit (if screenshots/docs added)**

```bash
git add -A
git commit -m "test: verify Gemini engine end-to-end (live API + VM)"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** TranslationModel (T2), Settings field+default+remember (T3), Gemini stream (T6,T7), two keychain slots (T5), provider-aware factory + env (T8), resampling 24k/16k (T4), per-model languages + coercion (T1,T2,T9), Settings UI (T9), Onboarding (T10), docs (T12), live + VM verification (T11,T13). All spec sections map to a task.
- **Placeholders:** none — code shown for every new artifact; boilerplate is precise mirror-references to `OpenAIRealtimeStream.swift` line ranges, not vague "implement similarly".
- **Type consistency:** `setTranslationModel`, `coerced`, `inputWireSampleRate`, `acceptedKeyPrefixes`, `loadAPIKey(for:)`, `GeminiClientEvent`/`GeminiServerEvent` used identically across tasks. `Resampler.toWire(_:targetSampleRate:)` and `AudioFormatTransformer.toWire(_:sampleRate:)` are distinct-by-design (free function vs protocol method) — both updated in T4.
- **Build-green invariant:** signature changes (T4 transformer, T5 keychain) update all call sites within the same task; UI VMs use `.openAIRealtime` as a placeholder in T5 and become model-aware in T9-T10.
