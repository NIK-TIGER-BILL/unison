# Выбор модели перевода (OpenAI / Gemini) — дизайн

*Дата: 2026-06-29*

## Цель

Дать пользователю выбор движка перевода: текущий OpenAI
`gpt-realtime-translate` **или** Google `gemini-3.5-live-translate-preview`.
Обе модели — audio→audio realtime-перевод; интегрируются через уже
существующий seam `TranslationStream` / `TranslationStreamFactory`, так что
оркестратор остаётся провайдер-агностичным.

## Зафиксированные продуктовые решения

1. **Где выбор:** и в онбординге, и в Настройках.
2. **Дефолт:** на первом запуске — OpenAI; далее выбор персистится в
   `Settings` (UserDefaults JSON-blob), т.е. «помним прошлый выбор» бесплатно.
3. **Ключи:** два независимых ключа в раздельных слотах Keychain
   (`openai-api-key`, `gemini-api-key`). Активная модель берёт свой ключ;
   переключение не затирает чужой.
4. **Языки:** список целевых языков зависит от модели. OpenAI — текущие 13.
   Gemini — кураторский набор ~25–30 (13 + ходовые: польский, нидерландский,
   турецкий, арабский, украинский, иврит, тайский, шведский, …). При
   переключении модели языки в паре, не поддерживаемые новой моделью,
   авто-коэрсятся на фоллбэк.

## Сравнение провайдеров (что диктует реализацию)

| | OpenAI (сейчас) | Gemini 3.5 Live Translate |
|---|---|---|
| Endpoint | `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate` | `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<KEY>` |
| Auth | `Authorization: Bearer <sk-…>` (header) | `?key=<AQ…>` (query) |
| Setup | `session.update` | `BidiGenerateContentSetup` |
| Target language | `session.audio.output.language` (ISO 639-1) | `translationConfig.targetLanguageCode` (BCP-47) |
| Вход аудио | 24 kHz int16 mono | **16 kHz** int16 mono |
| Выход аудио | 24 kHz int16 mono | 24 kHz int16 mono (совпадает) |
| Транскрипты | `…input/output_transcript.delta` | `serverContent.input/outputTranscription.text` |
| Граница хода | `output_transcript.done` + input-gap | `serverContent.turnComplete` + input-gap |
| Ключ | `sk-…` | `AQ.…` (новый Google auth-key формат) |

Коды языков enum'а (`ru`, `en`, `es`, …) валидны и как ISO 639-1, и как
BCP-47 primary subtag → `target.rawValue` подходит обеим моделям без таблицы
маппинга. Региональные варианты Gemini (`zh-Hans`, `pt-BR` и т.п.) в v1 не
вводим (YAGNI) — используем базовые коды, которые Gemini принимает.

## Изменения по слоям

### 1. `UnisonDomain` — доменная модель

**Новый enum** (`Sources/UnisonDomain/TranslationModel.swift`):

```swift
public enum TranslationModel: String, CaseIterable, Codable, Sendable {
    case openAIRealtime        // gpt-realtime-translate
    case geminiLiveTranslate   // gemini-3.5-live-translate-preview

    public var displayName: String              // "OpenAI Realtime", "Gemini 3.5 Live Translate"
    public var keychainAccount: String          // "openai-api-key" / "gemini-api-key"
    public var acceptedKeyPrefixes: [String]    // ["sk-"] / ["AQ.", "AIza"] — валидация
    public var apiKeyPlaceholder: String        // "sk-proj-…" / "AQ.…"
    public var getKeyURL: URL                    // куда вести по "Получить ключ"
    public var inputWireSampleRate: Int          // 24_000 / 16_000
    public var supportedTargets: [Language]      // 13 / ~25–30
    public var defaultLanguagePair: LanguagePair // фоллбэк для коэрсинга

    /// Привести пару к поддерживаемым языкам: каждый язык,
    /// которого нет в supportedTargets, заменяется на фоллбэк
    /// (стараясь не схлопнуть mine == peer).
    public func coerced(_ pair: LanguagePair) -> LanguagePair
}
```

Плоский enum (не «провайдер × модель»): сейчас по одной модели на провайдера,
расширяется добавлением кейса.

**`Settings`** (`Settings.swift`): добавить поле
`public var translationModel: TranslationModel`, дефолт `.openAIRealtime`.
Codable backward-compat — через `decodeIfPresent(...) ?? .openAIRealtime` в
кастомном `init(from:)` (тот же паттерн, что уже у `includedTapBundleIDs` /
`tapScopeMode`), плюс ключ в `CodingKeys`.

**`Language`** (`Language.swift`): добавить ~15 новых кейсов (Gemini-only):
`pl, nl, tr, ar, uk, he, th, sv, no, da, fi, cs, el, ro, hu` (финальный список
уточняется при реализации до ~25–30 суммарно). Для каждого — `displayName`
(русское имя) и `flagEmoji` (для языков без однозначного флага, напр. арабский,
— нейтральный глобус 🌐). Существующий `isTargetSupported` / `supportedTargets`
становится **модель-зависимым**: источник истины для пикера —
`selectedModel.supportedTargets`, а не статический `Language.supportedTargets`.

**`TranslationStream`** (`Protocols/TranslationStream.swift`): добавить
`nonisolated var inputWireSampleRate: Int { get }` — частота PCM, которую
провайдер ждёт в `send(_:)`. Реализуется как `nonisolated let` в actor'ах
(синхронное чтение из оркестратора без `await`).

### 2. `UnisonTranslation` — новый стрим Gemini

**`Sources/UnisonTranslation/GeminiLiveTranslateStream.swift`** — actor,
`TranslationStream`, зеркало `OpenAIRealtimeStream`. Переиспользует тот же
`WSClient` (`URLSessionWSClient`) и `TranslationError`.

Отличия от OpenAI-стрима:

- **URL с ключом в query.** Ключ percent-encoded. **URL c ключом НЕ логируем** —
  в диагностику пишем только хост + redacted-маркер.
- **connect(target:)** шлёт setup:
  ```json
  {"setup":{"model":"models/gemini-3.5-live-translate-preview",
    "generationConfig":{"responseModalities":["AUDIO"],
      "inputAudioTranscription":{},"outputAudioTranscription":{},
      "translationConfig":{"targetLanguageCode":"<target.rawValue>"}}}}
  ```
- **send(frame)** → `{"realtimeInput":{"audio":{"data":"<base64>","mimeType":"audio/pcm;rate=16000"}}}`.
- **Парсинг serverContent:**
  - `modelTurn.parts[].inlineData.data` (base64) → `AudioFrame(24kHz int16)`.
  - `inputTranscription.text` → `TranscriptDelta(kind: .original)`.
  - `outputTranscription.text` → `TranscriptDelta(kind: .translated)`.
  - `turnComplete == true` → ротация `currentEntryId` (граница хода). Input-gap
    фоллбэк (как у OpenAI) сохраняется на случай отсутствия сигнала.
  - `setupComplete` → `.connected` подтверждён; `goAway` / `interrupted` —
    в лог.
- **inputWireSampleRate = 16_000.**
- **classifyClose** — своя таблица под Gemini: close до прихода данных →
  `.apiKeyInvalid` (та же эвристика «handshake ок, потом дроп = креды/политика»);
  разбор error-payload и HTTP-статусов upgrade (401/403 → `.apiKeyInvalid`,
  429 → `.rateLimited`).
- `receivedAnyData` — выставляется только на реальном чанке перевода
  (audio/output-transcript), не на lifecycle-событиях (тот же инвариант, что у
  OpenAI, чтобы empty-close эскалация работала).

`OpenAIRealtimeStream` получает `inputWireSampleRate = 24_000` (стор-проп).

### 3. Ресемплинг (вариант B — параметризация)

Различается только **входная** частота (24k vs 16k); выход 24k у обоих →
inbound-путь (`fromWire(…, 48_000)`) не трогаем.

- `Resampler.toOpenAIWire(_:)` → обобщить в
  `Resampler.toWire(_ frame:, targetSampleRate: Int)`. Для 24k — поведение
  байт-в-байт прежнее (тот же fast-path и пайплайн). `fromOpenAIWire` →
  `fromWire` (уже параметризован по частоте; просто переименование).
- `AudioFormatTransformer.toWire(_:)` → `toWire(_ frame:, sampleRate: Int)`;
  `ResamplerAdapter` пробрасывает в `Resampler.toWire`.
- `TranslationOrchestrator`: два call-site (`wireOutgoingPipeline` ~1500,
  `wireIncomingPipeline` ~1622) меняют `transformer.toWire(frame)` →
  `transformer.toWire(frame, sampleRate: wireRate)`, где
  `let wireRate = stream.inputWireSampleRate` читается один раз до цикла.
  **Путь OpenAI остаётся идентичным побайтово** (передаётся 24_000).

Один ресемпл (лучшее качество), без double-resample, без новых зависимостей
между модулями (`UnisonTranslation` не тянет `UnisonAudio`).

### 4. `UnisonApp` (Composition) — фабрика и ключи

- **`KeychainService`** (`UnisonSystem`, импортирует `UnisonDomain`):
  методы параметризуются моделью —
  `loadAPIKey(for: TranslationModel)`, `saveAPIKey(_:for:)`,
  `deleteAPIKey(for:)`. `MacKeychain` хранит `service = "com.unison.app"`,
  `account = model.keychainAccount`. In-memory harness-keychain игнорирует
  параметр (возвращает свой pre-seeded ключ).
- **Провайдер-aware фабрика** заменяет `OpenAIRealtimeStreamFactory`:
  ```swift
  final class ProviderAwareStreamFactory: TranslationStreamFactory {
      let modelProvider: () -> TranslationModel        // settingsStore.load().translationModel
      let apiKeyProvider: (TranslationModel) -> String // env override → keychain(account)
      let clock: any Clock
      func make(speaker: Speaker) -> any TranslationStream {
          let model = modelProvider()
          let key = apiKeyProvider(model)
          switch model {
          case .openAIRealtime:      return OpenAIRealtimeStream(apiKey: key, client: URLSessionWSClient(), clock: clock, speaker: speaker)
          case .geminiLiveTranslate: return GeminiLiveTranslateStream(apiKey: key, client: URLSessionWSClient(), clock: clock, speaker: speaker)
          }
      }
  }
  ```
  Модель резолвится в момент `make` (= старт сессии), консистентно с правилом
  «scope резолвится один раз при start()».
- **Env-override:** существующий `UNISON_API_KEY` остаётся за OpenAI; добавить
  `UNISON_GEMINI_API_KEY`. `apiKeyProvider` выбирает по модели.

### 5. Пользовательская часть (UnisonUI)

**Настройки** (`SettingsView.swift`): секцию «OpenAI» переименовать в
**«Модель перевода»**:
- сверху `Picker` модели (паттерн как у языкового пикера — `LabeledContent` +
  `Binding(get:set:)` + `.pickerStyle(.menu)`), список = `TranslationModel.allCases`;
- ниже — поле ключа (`SecretInput`), адаптирующееся под выбранную модель:
  placeholder, валидация (`apiKeyPrefix`), ссылка «Получить ключ»
  (`getKeyURL`), слот Keychain (`keychainAccount`). Переключение пикера
  показывает ключ выбранного провайдера; второй не теряется.
- языковой пикер читает `vm.settings.translationModel.supportedTargets`;
  `setTranslationModel` коэрсит `languagePair` и эмитит изменение.

**Онбординг** (`OnboardingView.swift` / `OnboardingViewModel.swift`): в карточке
ключа добавить компактный выбор провайдера (segmented/menu, дефолт OpenAI). Поле
ключа, валидация (`validateAPIKey` становится модель-зависимой), сохранение
(в слот выбранной модели) и
gate-готовности (`status[.apiKey] == .done`) — все привязаны к **выбранной**
модели. «Получить ключ» ведёт на `model.getKeyURL`.

**ViewModels:** `SettingsViewModel` и `OnboardingViewModel` получают понятие
текущей выбранной модели; работа с ключом идёт через `keychain.*(for: model)`.

Копирайт — минимальный, в стиле проекта; UI русский.

### 6. Документация

Обновить `docs/audio-pipeline.md` (секция про модель → «две модели, общая
цепочка, разные wire-частоты/протоколы») и `README.md` (фича выбора модели,
второй ключ).

## Тестирование и верификация

- **Юнит-тесты (`UnisonTranslationTests`)**: `GeminiLiveTranslateStream` с mock
  `WSClient` — кодирование setup/realtimeInput; парсинг serverContent
  (audio/inputTranscription/outputTranscription/turnComplete); ротация entryId;
  `classifyClose` по кодам/payload; инвариант `receivedAnyData`.
- **`UnisonAudioTests`**: `Resampler.toWire(…, 16_000)` — корректная длина/частота;
  регресс на 24k (байт-в-байт со старым `toOpenAIWire`).
- **`UnisonDomainTests`**: `TranslationModel.supportedTargets`,
  `coerced(_:)` (включая защиту от mine == peer); Settings Codable
  backward-compat (старый blob без `translationModel` → `.openAIRealtime`).
- **`UnisonSystemTests`**: keychain per-account (два слота независимы).
- **`UnisonUITests`**: снапшоты Настроек (пикер модели) и онбординга
  (выбор провайдера) под `UNISON_FORCE_STATE`.
- **Полный прогон:** вся сюита + SwiftLint + сборка (`swift build`).
- **Живая проверка** против реального Gemini API тестовым ключом через
  `pacing-eval` (прогон продакшн-цепочки по WS) + VM-скриншот Настроек/онбординга
  на macOS 26 (Tart).

## Вне scope (YAGNI)

- Ephemeral-токены (v1alpha) — используем API-ключ напрямую (v1beta).
- Полный список 70+ языков и региональные варианты Gemini — кураторский набор.
- Выбор голоса/субмоделей внутри провайдера.
- Динамическая смена модели **посреди** активной сессии (модель резолвится на
  `start()`; смена применяется со следующей сессии — как и язык/устройства).

## Сводка затрагиваемых файлов

**Новые:** `UnisonDomain/TranslationModel.swift`,
`UnisonTranslation/GeminiLiveTranslateStream.swift`,
`UnisonTranslation/GeminiEvents.swift` (Codable-конверты), тест-файлы.

**Меняются:** `UnisonDomain/Settings.swift`, `UnisonDomain/Language.swift`,
`UnisonDomain/Protocols/TranslationStream.swift`,
`UnisonDomain/Protocols/AudioFormatTransformer.swift`,
`UnisonDomain/TranslationOrchestrator.swift` (2 call-site),
`UnisonAudio/Resampler.swift` (+ адаптер),
`UnisonTranslation/OpenAIRealtimeStream.swift` (+ `inputWireSampleRate`),
`UnisonSystem/MacKeychain.swift` + `KeychainService`,
`UnisonApp/Composition.swift` (фабрика, keychain, env),
`UnisonUI/Views/SettingsView.swift`,
`UnisonUI/ViewModels/SettingsViewModel.swift`,
`UnisonUI/Views/OnboardingView.swift`,
`UnisonUI/ViewModels/OnboardingViewModel.swift`,
`docs/audio-pipeline.md`, `README.md`.
