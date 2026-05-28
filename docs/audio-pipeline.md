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

**Важно**: `minRate = 1.0` означает что мы **не можем дренировать буфер быстрее реалтайма**. Если модель эмитит < 1.0× wall-clock на длинном отрезке, буфер опустошится → underrun. Это сознательный выбор: без floor=1.0 буфер мог бы overflow indefinitely при > 1.0× эмиссии. Замеренный `arrival_rate_ema ≈ 0.92-0.99x` ниже 1.0 на наших данных, поэтому при текущем `pipelineFrameBuffer=50` и `bufferingOldest` буфер не растёт бесконечно.

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
