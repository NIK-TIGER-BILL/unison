# Unison — Real-time голосовой переводчик для macOS

**Дата:** 2026-05-19
**Статус:** Design (после брейншторма, до implementation plan)

## 1. Контекст

Unison — desktop-приложение для macOS, которое переводит звонок в реальном времени между двумя языками (по умолчанию RU ↔ EN, настраиваемо). Использует одну OpenAI-модель `gpt-realtime-translate`, которая принимает аудио и отдаёт переведённое аудио без промежуточных STT/LLM/TTS-этапов.

Сценарий: пользователь в Zoom (или другом call-приложении). Жмёт Start в Unison — собеседник слышит синтезированный английский вместо русского пользователя; пользователь слышит синтезированный русский вместо английского собеседника.

## 2. Цели

- **Plug and play.** Установил приложение, нажал кнопку — работает. Минимум ручной настройки.
- **Минимализм UI.** Менюбар-иконка + один компактный popover. Никаких лишних экранов.
- **Низкая задержка.** OpenAI server-side VAD, чанки по ~100ms, нативный CoreAudio.
- **TDD.** Тесты пишутся первыми, особенно для domain-логики и парсинга API.
- **Прозрачность качества.** Live-транскрипт во время сессии, чтобы пользователь видел, что услышала модель.

## 3. Не-цели (MVP)

- Поддержка Windows/Linux.
- Запись звонков и хранение истории на диске (транскрипт — только в RAM на время сессии).
- Voice cloning (свой голос на другом языке) — используем дефолтные voices OpenAI.
- Перевод видео в браузере как основной use case (ScreenCaptureKit умеет, но в MVP — native call apps).
- Свой HAL-плагин / System Extension — используем готовый BlackHole.

## 4. Решения по продукту

| # | Решение | Обоснование |
|---|---------|-------------|
| 1 | **Tech stack:** Swift + SwiftUI | Нативные CoreAudio/ScreenCaptureKit, лучшие анимации, минимальный бандл |
| 2 | **Аудио-маршрутизация:** bundled BlackHole 2ch installer | Один ввод пароля при онбординге, де-факто стандарт |
| 3 | **Жизненный цикл сессии:** per-call toggle (Start/Stop) | Явный интент, прозрачность счёта OpenAI |
| 4 | **Языки:** два дропдауна (RU↔EN дефолт, ~10 языков) | Минимальный шум, максимум гибкости |
| 5 | **Форма приложения:** menu bar с popover | Невидимо когда не нужно, виден в menu bar когда активно |
| 6 | **Онбординг:** single-screen checklist | Прозрачно, без wizard-громоздкости |
| 7 | **Режимы работы:** Call (двусторонний) и Listen (только inbound) | Use case «смотрю видео» не требует BlackHole |
| 8 | **Транскрипт:** floating window поверх всех при активной сессии | Видимый индикатор работы + верификация качества |

## 5. Архитектура

### 5.1 Высокоуровневый поток аудио

**Исходящий канал** (моя речь → собеседнику):

```
mic (AVAudioEngine) → resampler 24kHz Int16 → WS OUT (target=peerLang)
                                                  ↓
                                        output_audio.delta
                                                  ↓
                                       resampler 48kHz F32
                                                  ↓
                              AVAudioEngine writes to BlackHole 2ch
                                                  ↓
                                    Zoom reads BlackHole 2ch as mic
```

**Входящий канал** (речь собеседника → мне):

```
Zoom audio → ScreenCaptureKit (filter: only Zoom app)
                                       ↓
                            resampler 24kHz Int16
                                       ↓
                          WS IN (target=myLang)
                                       ↓
                            output_audio.delta
                                       ↓
                            resampler 48kHz F32
                                       ↓
                  AVAudioEngine writes to default output (мои динамики)
```

Ключевые свойства:
- Нет feedback loop: SCKit фильтруется на Zoom-only, мы не пишем translated voice в default output, который ScreenCaptureKit ловит.
- Один BlackHole device (только 2ch), только для outgoing direction.
- Две WS-сессии независимы — отказ одной не валит вторую.
- Server-side VAD у OpenAI режет на utterance'ы.

### 5.2 Структура модулей (SPM workspace + app target)

```
unison/
├── Unison.xcodeproj
├── Package.swift
├── Sources/
│   ├── UnisonDomain/             # pure Swift, no system deps
│   ├── UnisonAudio/              # AVFoundation, ScreenCaptureKit, resampler
│   ├── UnisonTranslation/        # OpenAI realtime WS client
│   ├── UnisonSystem/             # Permissions, Keychain, BlackHole installer
│   ├── UnisonUI/                 # SwiftUI views
│   └── UnisonApp/                # composition root, AppDelegate
└── Tests/
    ├── UnisonDomainTests/
    ├── UnisonAudioTests/
    ├── UnisonTranslationTests/
    └── UnisonSystemTests/
```

### 5.3 Ключевые типы

```swift
// UnisonDomain
public enum Language: String { case ru, en, es, fr, de, it, pt, zh, ja, ko }
public struct LanguagePair { let mine: Language; let peer: Language }
public enum SessionMode { case call, listen }

public enum SessionState {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    case reconnecting(mode: SessionMode, since: Date)
    case error(TranslationError)
}

public enum TranslationError: Error {
    case permissionDenied(PermissionKind)
    case blackHoleMissing
    case apiKeyInvalid
    case rateLimited(retryAfter: TimeInterval)
    case insufficientCredits
    case networkLost
    case audioDeviceUnavailable
}

@MainActor @Observable
public final class TranslationOrchestrator {
    public private(set) var state: SessionState = .idle
    public private(set) var transcript: TranscriptStore

    public init(
        mic: MicrophoneCapture,
        appAudio: AppAudioCapture,
        defaultPlayer: AudioPlayer,
        blackHolePlayer: AudioPlayer,
        translationFactory: TranslationStreamFactory,
        permissions: PermissionsService,
        deviceRegistry: AudioDeviceRegistry,
        callAppDetector: CallAppDetector,
        clock: Clock
    )

    public func start(mode: SessionMode, languages: LanguagePair) async
    public func stop() async
}
```

### 5.4 Протоколы (для TDD-мокания)

```swift
// UnisonAudio
public protocol MicrophoneCapture {
    func start() -> AsyncStream<AudioFrame>  // 48kHz F32 mono
    func stop()
}
public protocol AppAudioCapture {
    func start(app: CallApp) -> AsyncStream<AudioFrame>
    func stop()
}
public protocol AudioPlayer {
    func play(_ frames: AsyncStream<AudioFrame>) async
    func stop()
}
public protocol AudioDeviceRegistry {
    func findBlackHole2ch() -> AudioDeviceID?
    func defaultOutputDevice() -> AudioDeviceID
}

// UnisonTranslation
public protocol TranslationStream {
    var transcripts: AsyncStream<TranscriptDelta> { get }
    var output: AsyncStream<AudioFrame> { get }
    var connectionState: AsyncStream<ConnectionState> { get }

    func connect(target: Language) async throws
    func send(_ frame: AudioFrame) async
    func close() async
}
public protocol TranslationStreamFactory {
    func make() -> TranslationStream
}

// UnisonSystem
public protocol PermissionsService {
    func currentStatus(_ kind: PermissionKind) -> PermissionStatus
    func request(_ kind: PermissionKind) async -> PermissionStatus
    func openSystemSettings(for: PermissionKind)
}
public protocol KeychainService {
    func loadAPIKey() -> String?
    func saveAPIKey(_ key: String) throws
}
public protocol BlackHoleInstaller {
    func isInstalled() -> Bool
    func runBundledInstaller() async throws
}
public protocol CallAppDetector {
    func knownApps() -> [CallApp]
    func runningApps() -> [CallApp]
}
```

## 6. Data flow / последовательность

### 6.1 Запуск приложения
1. SwiftUI App + AppDelegate создают `NSStatusItem` (иконка в menu bar).
2. Из `UserDefaults` читаются mode и LanguagePair, из Keychain — API key.
3. Если онбординг не пройден → открывается `OnboardingWindow`. Иначе — только menu bar икона.
4. State: `.idle`.

### 6.2 Открытие popover
1. Клик по menu bar икона → SwiftUI popover.
2. `PopoverView` биндится к `TranslationOrchestrator.state`.
3. Если permissions/BlackHole не готовы под текущий mode — Start задизейблен, под ним короткая подсказка.

### 6.3 Start translating
1. `Orchestrator.start(mode:, languages:)`.
2. State: `.idle → .connecting`.
3. Транскрипт-окно (floating `NSPanel`, `.floatingWindow` level, draggable) появляется на экране.
4. Иконка menu bar → pulsing animation.

**Call mode:**
- Проверка BlackHole 2ch в `AudioDeviceRegistry`. Нет — модалка с установщиком.
- Открываются две WS-сессии: OUT (target=peer) и IN (target=mine).
- `MicrophoneCapture.start()` → audio frames → resampler → `TranslationStream OUT.send()`.
- `AppAudioCapture.start(app:)` → resampler → `TranslationStream IN.send()`.
- `TranslationStream OUT.output` → resampler → `blackHolePlayer.play()`.
- `TranslationStream IN.output` → resampler → `defaultPlayer.play()`.

**Listen mode:**
- Запускается только IN session (target=mine).
- `AppAudioCapture.start(app:)` → `TranslationStream IN.send()`.
- `TranslationStream IN.output` → `defaultPlayer.play()`.
- BlackHole не трогается, mic permission не запрашивается.

5. Когда первая дельта приходит → state: `.connecting → .translating(startedAt: Date)`.

### 6.4 Во время сессии
- Audio frames льются непрерывно (~100ms chunks).
- `output_transcript.delta` события → `TranscriptStore.append(...)` → SwiftUI rerender transcript-окна.
- Cost counter в popover footer обновляется по startedAt.

### 6.5 Stop
1. `Orchestrator.stop()`.
2. Graceful close WS-сессий (`session.close` → wait `session.closed`, timeout 2s, потом hard).
3. Captures и players останавливаются.
4. Transcript-окно закрывается. Транскрипт остаётся в памяти до следующего Start (тогда очищается).
5. Иконка menu bar → idle.
6. State: `.idle`.

### 6.6 Quit во время сессии
- Cmd+Q → confirm-модалка → graceful stop → exit.

## 7. Аудио-формат

**Capture (системный side):** AVAudioEngine / ScreenCaptureKit отдают 48kHz Float32 mono (системный дефолт).

**Wire format (OpenAI):** 24kHz Int16 mono, base64 encoded в JSON-евентах WebSocket.

**Playback:** обратный путь — 24kHz Int16 → 48kHz Float32 → AVAudioEngine output.

**Chunk size:** 100ms = 2400 samples @ 24kHz. Достаточно для низкой задержки, не слишком частые WS-сообщения.

**Resampler:** чистая функция в `UnisonAudio`, тестируется на golden samples. Реализация — `vDSP` или `AVAudioConverter`.

## 8. Обработка ошибок

Все ошибки моделируются как `TranslationError` в `UnisonDomain`. `Orchestrator` — единственная точка перехода в `.error`. UI смотрит state и рендерит баннеры/тосты.

### Категории

| Категория | Триггеры | Поведение |
|-----------|----------|-----------|
| **Permissions** | mic denied, screen recording denied | Inline-баннер в popover, deep-link в System Settings, Start задизейблен |
| **BlackHole** | отсутствует, выбран как system output, исчез во время сессии | Модалка с установщиком; warning с авто-фиксом; graceful stop |
| **OpenAI API** | 401, 429, 5xx, 402 | Тост; auto-retry с `Retry-After`; reconnect; manual fix |
| **Network** | WS close 1006, длительный offline | Exponential backoff 1→30s per session, ring buffer 5s; toast после 30s |
| **Audio routing** | device hot-plug, call app не запущен | Прозрачное переключение или сообщение |
| **Logic** | юзер говорит на target-языке, одновременная речь, popover закрыт | Прозрачно (модель сама обрабатывает) |

### Reconnect logic

```
WS close detected → state .reconnecting
  ↓
attempt = 0
loop (внутри .reconnecting):
  delay = min(2^attempt, 30) seconds
  wait(delay)
  attempt += 1
  try reconnect
    → success: replay buffered audio (до 5s), state → .translating
    → failure: continue loop
  exit conditions:
    - user clicks Stop → state → .idle
    - total elapsed > 30s offline → state остаётся .reconnecting, но показываем
      toast «Connection lost» с кнопками Retry / Stop; loop продолжается в фоне
```

> UX-формулировки для всех баннеров/тостов будут дорабатываться отдельно на этапе UI-полировки (см. §11.1).

## 9. Стратегия тестирования (TDD)

### 9.1 Уровни

| Уровень | Доля | Что | Инструменты |
|---------|------|-----|-------------|
| **L1 Domain** | ~70% | State machine `Orchestrator`, типы, `TranscriptStore`, `CostEstimator`, error mapping | XCTest / Swift Testing в `UnisonDomain` |
| **L2 Translation** | ~15% | Парсинг OpenAI событий, encoding, reconnect/backoff с FakeWebSocket + FakeClock | XCTest в `UnisonTranslation` |
| **L3 Audio** | ~10% | Resampler (golden .wav samples), AudioBatcher, формат-конвертеры | XCTest + fixtures в `UnisonAudio` |
| **L4 Manual E2E** | ~5% | Runbook `docs/qa/release-checklist.md` | Ручной прогон на M-Mac, macOS 14+ |

### 9.2 TDD-порядок реализации

1. **UnisonDomain** целиком — все типы и state machine. Тесты → impl.
2. **UnisonTranslation** — протоколы + парсинг + reconnect logic с FakeWebSocket. Тесты → impl.
3. **UnisonAudio** — resampler и batcher с .wav fixtures. Тесты → impl.
4. **UnisonSystem** — протоколы (Keychain, Permissions, Installer). Тесты на mock-имплементациях. Реальные impl за ними.
5. **UnisonUI** + **UnisonApp** — связываем всё, ViewModels через мок-Orchestrator. Snapshot-тесты опционально.

### 9.3 CI

GitHub Actions, runner `macos-14`:
- `swift test` по всем SPM-модулям
- `xcodebuild test` для app target (только unit/snapshot, без real OpenAI/BlackHole)
- Code signing — отдельный release workflow с secrets

## 10. Системные требования

- **macOS 14 (Sonoma)** или новее — нужен `@Observable` и стабильный ScreenCaptureKit audio capture
- **Apple Silicon** в первую очередь; Intel — best effort
- **Developer ID + Notarization** — обязательно для bundled BlackHole installer
- **OpenAI API key** — пользователь предоставляет свой (BYOK), хранится в Keychain
- **Permissions:** Microphone, Screen Recording

## 11. TBD / открытые вопросы

### 11.1 UX-формулировки
Все user-facing строки (баннеры permissions, тосты ошибок, кнопки, заголовки в popover, hint'ы) — черновые, будут доработаны отдельной UI-итерацией под принцип минимализма.

### 11.2 Source transcript
OpenAI realtime-translate точно отдаёт `output_transcript.delta` (текст перевода). Транскрипт ИСХОДНОГО языка (что модель услышала) — нужно проверить, есть ли событие `input_audio_transcription.completed` у translation-сессии. Если нет — MVP показывает только переводы. Source — follow-up через параллельную `gpt-4o-transcribe` сессию.

### 11.3 Voice selection
Документация realtime-translate не упоминает выбор голоса. Используем дефолт. Если API exposes voice param — выносим в Settings (one voice for each direction).

### 11.4 Call app detection
В MVP — статичный список (Zoom, Teams, FaceTime, Discord, Slack). Юзер выбирает один в Settings. Auto-detect (по mic-usage) — follow-up.

### 11.5 Транскрипт-окно: формат содержимого
Внешний вид и layout floating-окна транскрипта прорабатывается отдельной UI-итерацией. В архитектуре: окно вызывается на Start, закрывается на Stop, всегда поверх, draggable.

### 11.6 Cost cap
Опциональный бюджет на месяц + блокировка при превышении — не в MVP. Архитектурный seam в `CostEstimator` оставлен.

## 12. Риски

| Риск | Митигация |
|------|-----------|
| **gpt-realtime-translate в бете / нестабильность API** | Адаптер `TranslationStream` за протоколом → можно подменить на STT+chat-completion+TTS fallback |
| **Bundled BlackHole installer ломает signing/notarization** | Bundle как отдельный helper-pkg, подписанный отдельно; тесты на свежей macOS VM до релиза |
| **OpenAI cost overrun у пользователя** | Live cost counter в popover footer; toast при подходе к настроенному порогу (TBD §11.6) |
| **Apple меняет policy на ScreenCaptureKit audio** | Изолировано в `UnisonAudio` за протоколом; fallback на BlackHole 16ch как inbound path |
| **Echo / feedback loop при неправильной настройке audio** | Onboarding-warning о BlackHole не выбирать как system output; runtime-detection в `AudioDeviceRegistry` |
| **Browser-based calls (Meet в Chrome) — общий audio Chrome** | MVP: не поддерживаем, документируем. Follow-up: process audio taps (macOS 14.4+) |

## 13. Следующий шаг

После approval этой спеки — `writing-plans` skill готовит implementation plan: разбиение на task-уровневые шаги, в порядке TDD-реализации из §9.2.
