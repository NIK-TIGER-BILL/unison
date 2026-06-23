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
│  WS: input_audio_buffer.append → OpenAI gpt-realtime-translate   │
│   │                                                              │
│  WS: session.output_audio.delta ← OpenAI                         │
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
→ WS → ... → BlackHole2chPlayer (peer's Zoom mic input).
```

---

## `gpt-realtime-translate` — поведение модели

Endpoint: `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`
(GA Translation endpoint, released ~mid-May 2026).

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

## Наша цепочка — компоненты

### `Resampler` (Sources/UnisonAudio/Resampler.swift)
Конверсия между wire-форматом (24k int16) и playback-форматом (48k F32).

- `toOpenAIWire(frame)` — для исходящих frames (mic/tap → OpenAI).
- `fromOpenAIWire(frame, targetSampleRate:)` — для входящих frames (OpenAI → speakers).
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

**Причина:** синхронный CoreAudio HAL teardown — Process-Tap
aggregate-device destroy (`ProcessTapCapture.teardown()`) и
`AVAudioEngine.stop()` (`AVAudioOutputMixer`/`BlackHole2chPlayer`) —
интермиттентно залипает в `coreaudiod` на много секунд или навсегда
(хуже всего на **Bluetooth**-выходе). `stopAllStreams()` уносит эти
вызовы в `Task.detached` (главный поток жив), но **ждал их `.value`**
перед `state = .idle` — поэтому залипший HAL прибивал всю сессию в
`.translating`: capture уже мёртв, Stop выглядит дохлым.

**Фикс:** `TranslationOrchestrator.teardownFinished(_:within:)` —
ограничивает ожидание teardown бюджетом `coreAudioTeardownBudgetSeconds`
(2 с). По истечении сессия идёт в `.idle`, а осиротевший teardown
доигрывает в фоне, если HAL оживёт. Плюс **сериализация**: каждый новый
teardown сцеплен за предыдущим (`pendingTeardown` + `await
previousTeardown?.value`), а `start()` ждёт незавершённый teardown перед
переиспользованием общего `AVAudioEngine` — иначе осиротевший teardown и
новый `start()`/`stop()` дёргали бы `engine.stop()`/Process-Tap destroy
конкурентно на одних объектах (это может уронить `coreaudiod`; stop()
компонентов идемпотентен только для *последовательных* вызовов).

Не интермиттентный в тестах: ловится через мок с блокирующимся `stop()`
(`MockAudioOutputMixer.blockStopUntilReleased`) + `InstantClock`.

**Остаётся:** при *перманентном* залипании HAL (устройство физически
исчезло) рестарт в том же процессе всё ещё переиспользует тот же
движок. Полная изоляция — пересоздавать `AVAudioEngine`/ноды per-session
(трекается отдельной задачей).

---

## Diagnostic env-vars

| Env var | Что делает |
|---|---|
| `UNISON_DUMP_PLAYBACK_WAV=/tmp/x.wav` | Tap на timePitch output — что mainMixer получил, 48kHz F32 mono |
| `UNISON_DUMP_WIRE_WAV=/tmp/x.wav` | Что **OpenAI вернула** (после decode base64) — 24kHz int16 mono |
| `UNISON_DUMP_SENT_WAV=/tmp/x.wav` | Что **мы послали** в OpenAI (после Resampler.toWire) — 24kHz int16 mono |
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
  swift run pacing-eval --audio /path/to/input.wav --target ru --runs 3

# Offline + Live playback тест (без OpenAI)
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

*Last updated: 2026-05-28*
