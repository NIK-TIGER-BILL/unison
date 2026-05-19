# Unison — Real-time голосовой переводчик для macOS

**Дата:** 2026-05-19
**Статус:** Design (после брейншторма, до implementation plan)

## 1. Контекст

Unison — desktop-приложение для macOS, которое переводит звонок в реальном времени между двумя языками (по умолчанию RU ↔ EN, настраиваемо). Использует одну OpenAI-модель `gpt-realtime-translate`, которая принимает аудио и отдаёт переведённое аудио без промежуточных STT/LLM/TTS-этапов.

Сценарий: пользователь в Zoom (или другом call/видео-приложении). Жмёт Start в Unison — собеседник слышит синтезированный английский вместо русского пользователя; пользователь слышит синтезированный русский поверх приглушённого оригинала собеседника.

## 2. Цели

- **Plug and play.** Установил, прошёл онбординг, нажал кнопку — работает. Минимум ручной настройки.
- **Минимализм UI.** Menu bar иконка + один компактный popover. Никаких лишних экранов.
- **Низкая задержка.** OpenAI server-side VAD, чанки ~100ms, нативный CoreAudio.
- **TDD.** Тесты пишутся первыми, особенно для domain-логики и парсинга API.
- **Прозрачность качества.** Live-транскрипт во время сессии + приглушённый оригинал как фон.

## 3. Не-цели (MVP)

- Поддержка Windows/Linux.
- Запись звонков и хранение истории на диске (транскрипт — только в RAM на время сессии).
- Voice cloning — используем дефолтные voices OpenAI.
- Свой HAL-плагин / System Extension — используем готовый BlackHole.

## 4. Решения по продукту

| # | Решение | Обоснование |
|---|---------|-------------|
| 1 | **Tech stack:** Swift + SwiftUI | Нативные CoreAudio API, лучшие анимации, минимальный бандл |
| 2 | **Аудио-маршрутизация:** bundled installer с двумя BlackHole (2ch + 16ch) | Чистый сигнал без echo, без Screen Recording permission, работает с любым source-приложением |
| 3 | **Жизненный цикл сессии:** per-call toggle (Start/Stop) | Явный интент, прозрачность счёта OpenAI |
| 4 | **Языки:** два дропдауна (RU↔EN дефолт, ~10 языков) | Минимальный шум, максимум гибкости |
| 5 | **Форма приложения:** menu bar с popover | Невидимо когда не нужно, виден в menu bar когда активно |
| 6 | **Онбординг:** single-screen checklist | Прозрачно, без wizard-громоздкости |
| 7 | **Режимы работы:** Call (двусторонний) и Listen (только inbound) | Use case «смотрю видео» не требует BlackHole 2ch и mic permission |
| 8 | **Транскрипт:** floating window поверх всех при активной сессии | Видимый индикатор работы + верификация качества |
| 9 | **Выбор устройств:** input mic и output для перевода — из системного списка, дефолт = system default | Поддержка AirPods/USB-mic; BlackHole-устройства скрыты |
| 10 | **Original mix:** приглушённый оригинал собеседника параллельно переводу, громкость 0–100% в Settings (дефолт 20%) | Контекстная подсказка, особенно полезно для несовершенного перевода |

## 5. Архитектура

### 5.1 Высокоуровневый поток аудио

**Исходящий канал** (моя речь → собеседнику):

```
selected input mic (AVAudioEngine) → resampler 24kHz Int16 → WS OUT (target=peerLang)
                                                                ↓
                                                      output_audio.delta
                                                                ↓
                                                     resampler 48kHz F32
                                                                ↓
                                  AVAudioEngine writes → BlackHole 2ch
                                                                ↓
                                                Zoom reads BlackHole 2ch as mic
```

**Входящий канал** (речь собеседника → мне):

```
Zoom output device = BlackHole 16ch (юзер настраивает в Zoom один раз)
                  ↓
Unison reads BlackHole 16ch as input
                  ↓
            split into two paths
       ┌─────────────────────┴─────────────────────┐
       ↓                                            ↓
resampler 24kHz Int16              gain × originalMixVolume
       ↓                                            ↓
WS IN (target=myLang)                              │
       ↓                                            ↓
output_audio.delta                                  │
       ↓                                            ↓
resampler 48kHz F32                                 │
       ↓                                            ↓
       └──────────→ AVAudioMixerNode ←──────────────┘
                            ↓
              AVAudioEngine output → selected output device
                            ↓
                       Юзер слышит: перевод (loud) + оригинал (тихо)
```

Ключевые свойства:

- **Нет echo:** Zoom output идёт в BlackHole 16ch, не в системные динамики. Юзер слышит ТОЛЬКО то, что играет наш AVAudioEngine.
- **Никакого ScreenCaptureKit / Screen Recording permission:** заменён прямым чтением BlackHole 16ch как audio input device.
- **Микс с оригиналом:** AVAudioMixerNode комбинирует переведённое аудио (gain=1.0) и пасс-тру оригинала (gain=settings.originalMixVolume, дефолт 0.2). При volume=0 оригинал не слышен совсем.
- **Outgoing direction независим:** наш голос собеседнику не микшируется ни с чем — туда идёт только перевод.
- **Две WS-сессии независимы** — отказ одной не валит вторую.
- **Server-side VAD у OpenAI** режет на utterance'ы автоматически.

### 5.2 Структура модулей (SPM workspace + app target)

```
unison/
├── Unison.xcodeproj
├── Package.swift
├── Sources/
│   ├── UnisonDomain/             # pure Swift, no system deps
│   ├── UnisonAudio/              # AVFoundation, CoreAudio, resampler, mixer
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

public struct Settings {
    var sessionMode: SessionMode
    var languagePair: LanguagePair
    var inputDeviceUID: String?      // nil = system default; UID для стабильности hot-plug
    var outputDeviceUID: String?     // nil = system default
    var originalMixVolume: Float     // 0.0..1.0, default 0.2
}

public enum SessionState {
    case idle
    case connecting(mode: SessionMode)
    case translating(mode: SessionMode, startedAt: Date)
    case reconnecting(mode: SessionMode, since: Date)
    case error(TranslationError)
}

public enum TranslationError: Error {
    case permissionDenied(PermissionKind)
    case blackHole2chMissing
    case blackHole16chMissing
    case apiKeyInvalid
    case rateLimited(retryAfter: TimeInterval)
    case insufficientCredits
    case networkLost
    case inputDeviceUnavailable
    case outputDeviceUnavailable
}

@MainActor @Observable
public final class TranslationOrchestrator {
    public private(set) var state: SessionState = .idle
    public private(set) var transcript: TranscriptStore

    public init(
        micCapture: MicrophoneCapture,
        peerCapture: PeerAudioCapture,
        outputMixer: AudioOutputMixer,
        virtualMicPlayer: AudioPlayer,
        translationFactory: TranslationStreamFactory,
        permissions: PermissionsService,
        deviceRegistry: AudioDeviceRegistry,
        clock: Clock
    )

    public func start(mode: SessionMode, languages: LanguagePair) async
    public func stop() async
    public func updateOriginalMixVolume(_ v: Float)
}
```

### 5.4 Протоколы (для TDD-мокания)

```swift
// UnisonAudio

// Capture из выбранного юзером input device (mic, AirPods)
public protocol MicrophoneCapture {
    func start(deviceUID: String?) -> AsyncStream<AudioFrame>   // nil = default
    func stop()
}

// Capture из BlackHole 16ch (фиксированное устройство, не юзер-конфигурируемое)
public protocol PeerAudioCapture {
    func start() -> AsyncStream<AudioFrame>
    func stop()
}

// Плеер в выбранный юзером output device, с миксом перевода и оригинала
public protocol AudioOutputMixer {
    func start(deviceUID: String?) async
    func playTranslated(_ frames: AsyncStream<AudioFrame>) async
    func playOriginal(_ frames: AsyncStream<AudioFrame>) async  // приглушается gain'ом
    func setOriginalGain(_ gain: Float)
    func stop()
}

// Плеер строго в BlackHole 2ch (фиксированное устройство)
public protocol AudioPlayer {
    func play(_ frames: AsyncStream<AudioFrame>) async
    func stop()
}

public protocol AudioDeviceRegistry {
    func availableInputDevices() -> [AudioDevice]      // для дропдауна mic
    func availableOutputDevices() -> [AudioDevice]     // для дропдауна output
    func findBlackHole2ch() -> AudioDevice?
    func findBlackHole16ch() -> AudioDevice?
    var deviceChanges: AsyncStream<Void> { get }       // hot-plug события
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
    func is2chInstalled() -> Bool
    func is16chInstalled() -> Bool
    func runBundledInstaller() async throws  // ставит оба пакета за один password prompt
}
```

## 6. Data flow / последовательность

### 6.1 Запуск приложения
1. SwiftUI App + AppDelegate создают `NSStatusItem` (иконка в menu bar).
2. Из `UserDefaults` читаются Settings, из Keychain — API key.
3. Если онбординг не пройден → открывается `OnboardingWindow`. Иначе — только menu bar икона.
4. State: `.idle`.

### 6.2 Открытие popover
1. Клик по menu bar иконке → SwiftUI popover.
2. `PopoverView` биндится к `TranslationOrchestrator.state`.
3. Если permissions/BlackHole не готовы под текущий mode — Start задизейблен, под ним короткая подсказка.
4. В footer popover отображаются выбранные устройства: `🎙 {input name} · 🔊 {output name}`. Клик → Settings.

### 6.3 Start translating
1. `Orchestrator.start(mode:, languages:)`.
2. State: `.idle → .connecting`.
3. Транскрипт-окно (floating `NSPanel`, `.floatingWindow` level, draggable) появляется на экране.
4. Иконка menu bar → pulsing animation.

**Call mode:**
- Проверка BlackHole 2ch и 16ch в `AudioDeviceRegistry`. Нет одного — модалка с установщиком.
- Открываются две WS-сессии: OUT (target=peer) и IN (target=mine).
- `MicrophoneCapture.start(settings.inputDeviceUID)` → resampler → `TranslationStream OUT.send()`.
- `PeerAudioCapture.start()` (читает BlackHole 16ch) → split:
  - копия 1 → resampler → `TranslationStream IN.send()`
  - копия 2 → `outputMixer.playOriginal()` (приглушённая)
- `TranslationStream OUT.output` → resampler → `virtualMicPlayer.play()` (BlackHole 2ch).
- `TranslationStream IN.output` → resampler → `outputMixer.playTranslated()` (loud).
- `outputMixer.start(settings.outputDeviceUID)` микширует translated+original в один выход.

**Listen mode:**
- BlackHole 2ch не нужен, mic не запрашивается. BlackHole 16ch — нужен.
- Запускается только IN session (target=mine).
- `PeerAudioCapture.start()` → split так же (translated path + original passthrough).
- `outputMixer.start(settings.outputDeviceUID)` — выход.

5. Когда первая дельта приходит → state: `.connecting → .translating(startedAt: Date)`.

### 6.4 Во время сессии
- Audio frames льются непрерывно (~100ms chunks).
- `output_transcript.delta` события → `TranscriptStore.append(...)` → SwiftUI rerender transcript-окна.
- Если юзер двинул в Settings слайдер «original mix volume» → `Orchestrator.updateOriginalMixVolume(v)` → `outputMixer.setOriginalGain(v)`. Применяется живьём без перезапуска сессии.
- Cost counter в popover footer обновляется по startedAt.

### 6.5 Stop
1. `Orchestrator.stop()`.
2. Graceful close WS-сессий (`session.close` → wait `session.closed`, timeout 2s, потом hard).
3. Captures и mixer останавливаются.
4. Transcript-окно закрывается. Транскрипт остаётся в памяти до следующего Start (тогда очищается).
5. Иконка menu bar → idle.
6. State: `.idle`.

### 6.6 Hot-plug устройства во время сессии
- `AudioDeviceRegistry.deviceChanges` события подписаны в `Orchestrator`.
- Если выбранный `inputDeviceUID` исчез → fallback на system default + toast.
- Если `outputDeviceUID` исчез → fallback на system default + toast.
- Если BlackHole 2ch/16ch исчез — `.error` state (см. §8).

### 6.7 Quit во время сессии
- Cmd+Q → confirm-модалка → graceful stop → exit.

## 7. Аудио-формат

**Capture (системный side):** AVAudioEngine отдают 48kHz Float32 mono (системный дефолт). BlackHole может быть 48kHz или 44.1kHz — нормализуем к 48kHz внутри.

**Wire format (OpenAI):** 24kHz Int16 mono, base64 encoded в JSON-евентах WebSocket.

**Playback:** обратный путь — 24kHz Int16 → 48kHz Float32 → AVAudioEngine output.

**Chunk size:** 100ms = 2400 samples @ 24kHz. Достаточно для низкой задержки, не слишком частые WS-сообщения.

**Resampler:** чистая функция в `UnisonAudio`, тестируется на golden samples. Реализация — `vDSP` или `AVAudioConverter`.

**Mixer:** `AVAudioMixerNode` с двумя input bus'ами (translated@1.0 + original@gain) → один output bus → output device.

## 8. Обработка ошибок

Все ошибки моделируются как `TranslationError` в `UnisonDomain`. `Orchestrator` — единственная точка перехода в `.error`. UI смотрит state и рендерит баннеры/тосты.

### Категории

| Категория | Триггеры | Поведение |
|-----------|----------|-----------|
| **Permissions** | mic denied | Inline-баннер в popover, deep-link в System Settings, Start задизейблен в Call mode (Listen работает) |
| **BlackHole 2ch** | отсутствует (нужен только в Call), выбран как system output, исчез во время сессии | Модалка с установщиком; warning с авто-фиксом; graceful stop |
| **BlackHole 16ch** | отсутствует (нужен в обоих режимах), исчез во время сессии | Модалка с установщиком; graceful stop |
| **OpenAI API** | 401, 429, 5xx, 402 | Тост; auto-retry с `Retry-After`; reconnect; manual fix |
| **Network** | WS close 1006, длительный offline | Exponential backoff 1→30s per session, ring buffer 5s; toast после 30s |
| **Input/output device** | выбранное устройство пропало | Fallback на system default + короткий toast |
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
| **L1 Domain** | ~70% | State machine `Orchestrator`, типы, `TranscriptStore`, `CostEstimator`, error mapping, settings | XCTest / Swift Testing в `UnisonDomain` |
| **L2 Translation** | ~15% | Парсинг OpenAI событий, encoding, reconnect/backoff с FakeWebSocket + FakeClock | XCTest в `UnisonTranslation` |
| **L3 Audio** | ~10% | Resampler (golden .wav samples), AudioBatcher, gain-multiplier, формат-конвертеры | XCTest + fixtures в `UnisonAudio` |
| **L4 Manual E2E** | ~5% | Runbook `docs/qa/release-checklist.md` | Ручной прогон на M-Mac, macOS 14+ |

### 9.2 TDD-порядок реализации

1. **UnisonDomain** целиком — все типы, Settings, state machine. Тесты → impl.
2. **UnisonTranslation** — протоколы + парсинг + reconnect logic с FakeWebSocket. Тесты → impl.
3. **UnisonAudio** — resampler и batcher с .wav fixtures + gain mixer. Только потом реальные движки.
4. **UnisonSystem** — протоколы (Keychain, Permissions, Installer). Impl за ними.
5. **UnisonUI** + **UnisonApp** — связываем всё, ViewModels через мок-Orchestrator. Snapshot-тесты опционально.

### 9.3 CI

GitHub Actions, runner `macos-14`:
- `swift test` по всем SPM-модулям
- `xcodebuild test` для app target (только unit/snapshot, без real OpenAI/BlackHole)
- Code signing — отдельный release workflow с secrets

## 10. Системные требования

- **macOS 14 (Sonoma)** или новее — нужен `@Observable`
- **Apple Silicon** в первую очередь; Intel — best effort
- **Developer ID + Notarization** — обязательно для bundled BlackHole installer
- **OpenAI API key** — пользователь предоставляет свой (BYOK), хранится в Keychain
- **Permissions:** Microphone (только для Call mode). Screen Recording НЕ нужен.

## 11. TBD / открытые вопросы

### 11.1 UX-формулировки
Все user-facing строки — черновые, доработка отдельной UI-итерацией под минимализм.

### 11.2 Source transcript
OpenAI realtime-translate точно отдаёт `output_transcript.delta`. Source transcript (что услышала модель) — проверить, есть ли `input_audio_transcription.completed` событие у translation-сессии. Если нет — MVP показывает только переводы.

### 11.3 Voice selection
Документация realtime-translate не упоминает выбор голоса. Используем дефолт. Если API exposes — выносим в Settings.

### 11.4 Default `originalMixVolume`
Дефолт 20%. Проверить на реальных звонках — возможно, дефолт стоит сделать 0% (тишина) и явно включать в Settings.

### 11.5 Транскрипт-окно: формат содержимого
Внешний вид и layout floating-окна транскрипта прорабатывается отдельной UI-итерацией.

### 11.6 Cost cap
Опциональный месячный бюджет — не в MVP. Архитектурный seam в `CostEstimator` оставлен.

## 12. Риски

| Риск | Митигация |
|------|-----------|
| **gpt-realtime-translate в бете / нестабильность API** | Адаптер `TranslationStream` за протоколом → можно подменить на STT+chat-completion+TTS fallback |
| **Bundled BlackHole installer ломает signing/notarization** | Bundle оба пакета как helper'ы, подписанные отдельно; тесты на свежей macOS VM до релиза |
| **OpenAI cost overrun у пользователя** | Live cost counter в popover footer; toast при подходе к настроенному порогу (TBD §11.6) |
| **Юзер не настроил Zoom Speaker = BlackHole 16ch** | Onboarding-инструкция явно; в первой сессии: если в BlackHole 16ch нет звука дольше 10 сек после Start → toast «Похоже, в Zoom не выбран BlackHole 16ch как speaker» |
| **Echo / feedback loop при неправильной настройке audio** | Onboarding-warning о BlackHole-устройствах не выбирать как system input/output юзером; runtime-detection в `AudioDeviceRegistry` |

## 13. Следующий шаг

После approval этой спеки — `writing-plans` skill готовит implementation plan: разбиение на task-уровневые шаги, в порядке TDD-реализации из §9.2.
