# Audio Pipeline — Knowledge Base

Накопленные знания о работе с аудио — модель, наша цепочка, известные
проблемы и их обходы. Документ живой, пополняем по мере находок.

---

## Высокоуровневая схема

```
┌─ INCOMING (peer → user) ────────────────────────────────────────┐
│                                                                  │
│  System audio                                                    │
│   │ Process Tap (CoreAudio)                                      │
│   ▼                                                              │
│  ProcessTapCapture (48 kHz F32 mono AudioFrame)                  │
│   │ Resampler.toWire    [48k F32 → 24k int16]                   │
│   ▼                                                              │
│  WS: (audio input) → TranslationStream (OpenAI or Gemini)         │
│   │                                                              │
│  WS: (audio output delta) ← TranslationStream                    │
│   │ Resampler.fromWire  [24k int16 → 48k F32]                   │
│   ▼                                                              │
│  AVAudioOutputMixer:                                             │
│   │ CompensatingAGCRunner.apply        [counter-fade gain]      │
│   │ scheduleBuffer                                               │
│   ▼                                                              │
│  AVAudioPlayerNode → AVAudioUnitTimePitch → mainMixer            │
│   │ (PlaybackPacing modulates timePitch.rate based on buffer    │
│   │  depth — stays at 1.0 in 95 %+ of ticks on normal content)  │
│   ▼                                                              │
│  outputNode → device (speakers / BT / etc.)                      │
└──────────────────────────────────────────────────────────────────┘

OUTGOING (user → peer) — symmetric structure: mic → Resampler.toWire
→ WS → TranslationStream → ... → BlackHole2chPlayer (peer's Zoom mic input).
```

---

## Движки перевода

За одним интерфейсом `TranslationStream` скрываются два взаимозаменяемых движка.
Выбор хранится в `Settings.translationModel` (дефолт — `.openAIRealtime`) и
разрешается **однократно в момент `start()`** через `ProviderAwareStreamFactory` —
смена движка вступает в силу на следующей сессии (как смена языка или устройства).
**Output у обоих движков 24 kHz** int16 mono; различается только входная rate
(OpenAI ожидает 24 kHz, Gemini — 16 kHz). Оркестратор читает
`TranslationStream.inputWireSampleRate` и ресемплирует исходящее аудио через
`Resampler.toWire(_:targetSampleRate:)` перед отправкой.

---

### OpenAI `gpt-realtime-translate`

Endpoint: `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`
(GA Translation endpoint, released ~mid-May 2026).
Auth: `Authorization: Bearer <sk-…>` header.
Input: **24 kHz** int16 mono. Output: 24 kHz int16 mono.
Поддерживаемых target языков: **13**.

### Конфигурация (`session.update`)

```json
{
  "type": "session.update",
  "session": {
    "audio": {
      "input": {
        "transcription": {"model": "gpt-realtime-whisper"},
        "noise_reduction": {"type": "near_field"}
      },
      "output": {"language": "<ISO 639-1 target>"}
    }
  }
}
```

- **No `instructions`, `voice`, `modalities`, `turn_detection`** — этот endpoint их не поддерживает.
- **`noise_reduction`**: input-side processing на стороне OpenAI:
  - `near_field` — для микрофонной записи (агрессивный noise suppression + AGC). Дефолт по cookbook.
  - `far_field` — для room mic.
  - `null` (явно) или omitted — без NR.
  - **На наш fade-баг влияния не оказывает** (тестировали и так и так).

### Чанки I/O

- **Input chunks** — любого размера; cookbook рекомендует 50ms, мы шлём 100ms (24 kHz int16, ~2400 samples = 4800 bytes на чанк). Шлём непрерывно включая тишину.
- **Output chunks** — обычно ~200ms но варьируется (видим 200-400ms у нас). 24kHz int16 mono.
- **Output emission timing** — НЕ строго real-time. Длинная сессия = бёрсты после clause-boundary с потенциальными pauses до 0.5-1 секунды между чанками (на медленной речи — до 5+ секунд).

### Long-run output amplitude rate

Замеренные значения:
- Avg arrival rate ≈ **0.92-0.99x от real-time** (модель шлёт МЕДЛЕННЕЕ wall-clock в среднем).
- Это значит **очередь не может расти неограниченно** в стабильной сессии.

### 🔥 Известный баг — Progressive Output Amplitude Fade

**Симптом:** На непрерывной сессии модель прогрессивно подавляет амплитуду
своего собственного output, даже если input стабильный по громкости.

**Замеры (наш harness, ~25 секунд непрерывной речи):**
- Input RMS (что мы посылаем): стабильный 0.05-0.07, slope ≈ 0
- Output RMS (что модель возвращает): Q1=0.05, Q4=0.015 (**-56-66 %**)
- Сбрасывается на паузе ≥ 3 секунд тишины — следующая фраза снова громкая

**Что НЕ помогает:**
- `noise_reduction: null` — то же поведение
- `noise_reduction: far_field` — то же
- Pre-roll буфер на нашей стороне — не имеет отношения
- Перезапуск Resampler — у нас на стороне всё ок

**Что помогает:**
- **Естественные паузы** в источнике (≥3 сек тишины) — модель сбрасывает state
- **Наш `CompensatingAGCRunner`** — клиентский AGC компенсирует на нашей стороне (см. ниже)

**Зарепортить в OpenAI?** Не нашли публичных репортов (модель новая, ~3 недели на момент детекта).
В планах — мин-repro и issue.

---

### Gemini `gemini-3.5-live-translate-preview`

Endpoint:
```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=<KEY>
```
Auth: API-ключ в **query-параметре** URL (без заголовка; ключ **никогда не логируется**).
Input: **16 kHz** int16 mono. Output: 24 kHz int16 (base64). Поддерживаемых target языков: **~28** (curated subset из 70+).

#### Конфигурация (setup message)

```json
{
  "setup": {
    "model": "models/gemini-3.5-live-translate-preview",
    "generationConfig": {
      "translationConfig": {
        "targetLanguageCode": "<BCP-47>"
      },
      "responseModalities": ["AUDIO"],
      "inputAudioTranscription": {},
      "outputAudioTranscription": {}
    }
  }
}
```

Тип сообщения: `BidiGenerateContentSetup`.

#### Отправка аудио

```json
{
  "realtimeInput": {
    "audio": {
      "mimeType": "audio/pcm;rate=16000",
      "data": "<base64 int16 16kHz>"
    }
  }
}
```

#### Ответ сервера (`serverContent`)

```json
{
  "serverContent": {
    "modelTurn": {
      "parts": [{ "inlineData": { "mimeType": "audio/pcm;rate=24000", "data": "<base64>" } }]
    },
    "inputTranscription": { "text": "..." },
    "outputTranscription": { "text": "..." },
    "turnComplete": true
  }
}
```

Аудио: `modelTurn.parts[].inlineData.data` (base64 24 kHz int16 mono).
Транскрипции: `inputTranscription.text` (оригинал) / `outputTranscription.text` (перевод).
Конец реплики: `turnComplete: true`.

---

## Наша цепочка — компоненты

### `Resampler` (Sources/UnisonAudio/Resampler.swift)
Конверсия между wire-форматом движка и playback-форматом (48k F32).

- `toWire(_:targetSampleRate:)` — для исходящих frames (mic/tap → движок).
  Оркестратор передаёт `TranslationStream.inputWireSampleRate` (24 kHz для OpenAI, 16 kHz для Gemini).
- `fromWire(_:)` — для входящих frames (движок → speakers); output всегда 24 kHz.
- Использует **cached AVAudioConverter** — один экземпляр на (srcRate, dstRate, channels).
  `.reset()` перед каждым чанком чтобы изолировать состояние от предыдущего вызова.
- Кэш статический lock-protected (двунаправленный pipeline вызывает одновременно).

### `PlaybackPacing` v3 — lenient (Sources/UnisonAudio/PlaybackPacing.swift)
Safety net controller для адаптивного TimePitch.rate.

| Константа | Значение | Смысл |
|---|---|---|
| `targetBufferSec` | 1.0 | Ниже этого rate=1.0 (controller silent) |
| `correctionGain` | 0.3 | Пологий slope |
| `maxRate` | 1.5 | Cap на ускорение |
| `minRate` | 1.0 | НИКОГДА не приглушаем (даже на underrun) |
| `maxRateStepPerTick` | 0.05 | Slew = 0.5/сек — плавно |

На реальном контенте в наших тестовых записях rate **стоит на 1.000 на протяжении всей сессии** — controller вступает только при патологическом overflow (depth > 1s sustained, что мы пока ни разу не видели в production).

**Важно**: `minRate = 1.0` — мы **не можем играть медленнее реалтайма**. Это сознательный выбор:
- Если модель эмитит **> 1.0×** wall-clock на длинном отрезке (бёрст/verbose target) — без floor рейт мог бы упасть < 1.0, и буфер раздул бы латентность indefinitely. Floor → controller обязан ускоряться вверх или держать 1.0
- Если модель эмитит **< 1.0×** (наш наблюдаемый случай: `arrival_rate_ema ≈ 0.92-0.99x`) — буфер постепенно опустошается → underrun неизбежен. Floor ничего не делает, controller бессилен

В наших данных модель устойчиво ниже 1.0×, поэтому реальный риск — underrun (тишина между чанками), а не overflow. `pipelineFrameBuffer=50` + `bufferingOldest` гарантируют что буфер не растёт > 5 секунд даже в патологических сценариях.

### `CompensatingAGCRunner` (Sources/UnisonAudio/CompensatingAGC.swift)
Компенсация для model fade (см. выше).

| Константа | Значение | Смысл |
|---|---|---|
| `targetRMS` | 0.05 | Уровень свежей сессии модели |
| `maxGain` | 4.0 | +12 dB potential |
| `minGain` | 1.0 | Только бустим, никогда не глушим |
| `rmsAlpha` | 0.02 | EMA τ ≈ 5 сек |
| `gainSlewPerFrame` | 0.02 | Slew 0.2/сек — без пампинга |
| `silenceFloor` | 0.005 | Ниже — silence, не апдейтим EMA, не бустим |
| `resetSilenceSec` | 3.0 | После 3с silence — снос к начальному state |

Применяется в обоих плеерах (`AVAudioOutputMixer` для local listening, `BlackHole2chPlayer` для virtual mic).

### `AVAudioOutputMixer` (Sources/UnisonAudio/AVAudioOutputMixer.swift)
Локальное проигрывание (что слышит пользователь).

- Два player: `translatedPlayer` (vol 1.0) + `originalPlayer` (vol 0.2 настраиваемый)
- `AVAudioUnitTimePitch` между translatedPlayer и mainMixer для адаптивного rate
- Output device — `settings.outputDeviceUID` (default device если не указан)

### `BlackHole2chPlayer` (Sources/UnisonAudio/BlackHole2chPlayer.swift)
Virtual mic для пира — выводит переведённый user audio в BlackHole 2ch, который видеоконф-app использует как мик.

- Та же node-цепочка что в outputMixer для translated path
- AGC применяется на стороне peer'а тоже

### 🔥 Известный баг — Stop зависает (teardown wedge)

**Симптом:** кнопка Stop иногда «не срабатывает» / «зависает», звук
пропадает. По логам `stop()` обрывается на `[tap.stop] reason=user` и
никогда не доходит до `state … → idle` (см. `unison.log` pid=13100,
pid=83933).

**Корневая причина (найдена в VM, детерминированно):**
`AVAudioOutputMixer.stop()` звал `translatedPlayer.stop()` /
`originalPlayer.stop()`. **`AVAudioPlayerNode.stop()`** сбрасывает (flush)
накопившиеся `.dataPlayedBack` completion-хендлеры из `scheduleTranslated`,
и этот flush **никогда не возвращается**, если в сессии был активен
Process Tap — залипает в `coreaudiod` (хуже всего на **Bluetooth**).
Так как залипший `stop()` блокировал весь teardown, сессия не доходила
до `.idle`. A/B на свежезагруженном `coreaudiod` (`scripts/vm-verify-fix.sh`,
`Tools/TapBenchmark/ReproTeardown.swift`): продакшн-путь mixer'а клинит
Stop 3/3 с `stop()` и чисто проходит 3/3 с `reset()`. Сам `AVAudioEngine.stop()`
и все четыре HAL-destroy (`AudioDeviceStop`/`…DestroyIOProcID`/
`…DestroyAggregateDevice`/`…DestroyProcessTap`) возвращаются мгновенно —
это **не** они.

**Корневой фикс:** `AVAudioOutputMixer.stop()` теперь `reset()` (а не
`stop()`) на плеерах — очищает запланированные буферы без flush'а
completion-хендлеров.

**Защита в глубину (PR #7):** `TranslationOrchestrator.teardownFinished(_:within:)`
ограничивает ожидание teardown бюджетом `coreAudioTeardownBudgetSeconds`
(2 с) — на случай *системного* залипания `coreaudiod` вне нашего контроля.
По истечении сессия идёт в `.idle`, осиротевший teardown доигрывает в фоне.
Плюс **сериализация**: каждый новый teardown сцеплен за предыдущим
(`pendingTeardown` + `await previousTeardown?.value`), а `start()` ждёт
незавершённый teardown перед переиспользованием общего `AVAudioEngine` —
иначе teardown и новый `start()`/`stop()` дёргали бы `engine.stop()`/
Process-Tap destroy конкурентно на одних объектах (может уронить
`coreaudiod`; stop() компонентов идемпотентен только для *последовательных*
вызовов).

Не интермиттентный в тестах: ловится через мок с блокирующимся `stop()`
(`MockAudioOutputMixer.blockStopUntilReleased`) + `InstantClock`.

**Остаётся:** корневой фикс (`reset()`) снимает залипание от нашего же
teardown, поэтому отдельная пересборка `AVAudioEngine` per-session больше
не нужна; бюджет + сериализация остаются как защита от перманентного
залипания HAL (устройство физически исчезло).

---

## Process Tap scope — исключения / «только выбранные»

`ProcessTapCapture` решает, **что** захватывать, через `TapScope`:

- `.allExcept(bundleIDs)` → `CATapDescription(monoGlobalTapButExcludeProcesses:)` —
  захватываем весь системный звук, кроме выбранных (+ всегда сам Unison, анти-фидбек).
- `.onlySelected(bundleIDs)` → `CATapDescription(monoMixdownOfProcesses:)` —
  захватываем **только** выбранные процессы; себя не таппим.

`muteBehavior = .mutedWhenTapped`: то, что попало в tap, глушится на устройстве,
а Unison проигрывает перевод (+ тихий оригинал через `originalPlayer`, vol 0.2).
Не-затаппленные приложения играют на 100 %.

### Резолв bundle ID → audio objects (`AudioProcessRegistry.audioObjectIDs(forBundleID:)`)

🔥 **Многие приложения издают звук из helper/XPC-процесса, а не из главного, и
bundle ID хелпера ненадёжен** (Yandex Music → `…music.helper` — ребёнок; Dia →
общий `company.thebrowser.browser.helper` — другое поддерево). Любые правила
вида «префикс bundle ID» или «путь внутри бандла» приходится чинить под каждое
новое приложение.

Поэтому матчим не по bundle ID, а спрашиваем у системы, **кто отвечает** за
процесс — та же атрибуция app↔helper, что использует TCC и группировка
процессов в Activity Monitor:

1. **Основной, универсальный:** `responsibility_get_pid_responsible_for_pid(pid)`
   (SPI libsystem, берём через `dlsym` — нет символа → деградирует в nil, не
   ломая линковку) → responsible PID → `NSRunningApplication(...).bundleIdentifier`.
   Разрешает **любой** helper/renderer/XPC в его приложение-владельца без
   правил-под-каждое-приложение. Проверено: Claude/Yandex/Dia-хелперы все
   маппятся в свой главный bundle ID.
2. **Фоллбэк** (только если SPI недоступен): исполняемый файл процесса
   (`proc_pidpath`) лежит **внутри** бандла приложения
   (`NSWorkspace.urlForApplication(withBundleIdentifier:)`).

Возвращаем **все** совпавшие объекты (у приложения может быть несколько
audio-хелперов). Без этого исключённое/включённое приложение таппится мимо —
в blocklist всё переводится, а в allowlist mixdown берёт только тихий главный
процесс (нет транскрипта, приложение не глушится).

### Резолв — один раз при `start()`

Область захвата резолвится **однократно** при старте сессии: приложение должно
**уже издавать звук**, когда нажата «Начать», иначе у него ещё нет Audio Process
Object и оно не попадёт в tap до перезапуска сессии.

⚠️ **Не возвращать динамический слушатель.** Была попытка держать tap «живым»
через listener на `kAudioHardwarePropertyProcessObjectList` + live-`AudioObjectSetPropertyData(kAudioTapPropertyDescription)` —
**зависала кнопка Stop и приложение падало** (HAL-set на главном потоке +
правка живого tap клинила teardown). Слушатель стоял только при непустом
списке — ровно эти сессии и зависали. Удалено. Если динамика реально нужна —
делать вне главного потока и через пересоздание tap, не правкой живого.

⚠️ **Пустой allowlist-резолв → НЕ создавать tap.** `monoMixdownOfProcesses:[]`
(или mixdown из процессов, не дающих звука) клинит CoreAudio на teardown (тот же
Stop-hang). При пустом резолве `.onlySelected` держим поток открытым, но пустым
(захвата нет, останавливается чисто).

## Diagnostic env-vars

| Env var | Что делает |
|---|---|
| `UNISON_DUMP_PLAYBACK_WAV=/tmp/x.wav` | Tap на timePitch output — что mainMixer получил, 48kHz F32 mono |
| `UNISON_DUMP_WIRE_WAV=/tmp/x.wav` | Что **движок вернул** (после decode base64) — 24kHz int16 mono |
| `UNISON_DUMP_SENT_WAV=/tmp/x.wav` | Что **мы послали** в движок (после Resampler.toWire) — int16 mono (24k/16k в зависимости от движка) |
| `UNISON_NOISE_REDUCTION=off\|near_field\|far_field` | Override `noise_reduction` в `session.update` |
| `UNISON_FORCE_STATE=...` | Snapshot/harness mode forcings |

Пример полной диагностической запуска:
```bash
killall Unison
UNISON_DUMP_SENT_WAV=/tmp/sent.wav \
UNISON_DUMP_WIRE_WAV=/tmp/wire.wav \
UNISON_DUMP_PLAYBACK_WAV=/tmp/playback.wav \
open /Applications/Unison.app
```

---

## `pacing-eval` CLI Harness

`swift run pacing-eval` — автономный инструмент для прогона аудио через
production-цепочку без юзера. Source: `Sources/Tools/PacingEval/`.

```bash
# Реальная сессия с OpenAI на pre-recorded WAV
OPENAI_API_KEY=$(security find-generic-password -s "com.unison.app" -a "openai-api-key" -w) \
  swift run pacing-eval --provider openai --audio /path/to/input.wav --target ru --runs 3

# Реальная сессия с Gemini
GEMINI_API_KEY=$(security find-generic-password -s "com.unison.app" -a "gemini-api-key" -w) \
  swift run pacing-eval --provider gemini --audio /path/to/input.wav --target ru --runs 3

# Offline + Live playback тест (без подключения к движку)
swift run pacing-eval --audio /path/to/input.wav --playback-test
```

Возможности:
- Прогон через реальную OpenAI Realtime API сессию
- Запись arrival timestamps + raw model output как WAV
- Симуляция PlaybackPacing на recorded timeline
- Variant sweep (pre-roll, fixed rate, etc.)
- RMS analysis per-second + квартили
- Сравнение offline-render vs live-render

Фикстуры:
- `Tests/Fixtures/audio/{ru,en}-monologue-{normal,fast}.wav` — синтезированные через `say` + `afconvert`
- Генерация: `bash Tests/Fixtures/audio/generate.sh`

---

## Открытые вопросы / TODO

- [ ] Минимальное repro для OpenAI bug report (gpt-realtime-translate fade)
- [ ] Quality degradation (не только громкость) — нужно отдельное расследование
- [ ] Куски аудио прерываются до окончания — расследуется

---

*Last updated: 2026-06-29*
