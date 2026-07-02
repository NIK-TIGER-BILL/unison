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

#### Пейринг оригинал ↔ перевод в бабблы (два трека + FIFO, 2026-07-02)

**Баг (скриншот юзера):** каждый баббл держал перевод фразы N + оригинал
фразы N+1. Перевод отстаёт от оригинала, и `inputTranscription` следующей
фразы прилетает ДО `turnComplete` предыдущей — при общем `currentEntryId` он
приклеивался к прошлому бабблу, и весь транскрипт ехал «на один».

**Модель:** оригиналы пишутся в `inputEntryId`; он ротируется на **речевой
паузе** — гэп входа ≥0.6с (это по построению граница VAD-тёрна: сервер режет
тёрн на ~0.3с тишины), взведённой только когда перевод текущего тёрна уже
начался (`sawOutputForCurrentInput`; защита от джиттера доставки текста) или
вход уже убежал на тёрн вперёд. Грубый фолбэк ≥5с остался. Переводы пишутся в
голову FIFO `pendingTurnEntries` (реплики в порядке речи); `turnComplete`
выталкивает голову. Пропущенная граница входа деградирует к старому поведению
(склейка + ротация на turnComplete) — но больше не СДВИГАЕТ пейринг. Кап
очереди 3 (потерянные turnComplete не приколачивают переводы к древнему
бабблу). Лог: `[pairing <speaker>]`. Тесты:
`lateTranslation_pairsWithItsOwnUtterance_notTheNext` и соседние.
OpenAI-стрим не трогали: у translations-эндпоинта нет тёрнов вообще
(и item_id тоже), там по-прежнему только 5с-гэп.

---

## Наша цепочка — компоненты

### `Resampler` / `StreamingResampler` (Sources/UnisonAudio/)
Конверсия между wire-форматом движка и playback-форматом (48k F32).

**Два пути с разными семантиками:**

- **`StreamingResampler`** (прод, live-пайплайны) — stateful: конвертер на
  (src→dst) направление **на инстанс**, состояние фильтра **сохраняется
  между чанками** (`.noDataNow` вместо `.endOfStream`, без truncate/zero-pad;
  длина выхода — сколько отдал конвертер). Оркестратор берёт **по инстансу
  на пайплайн** через `AudioFormatTransformer.makeStreamTransformer()` — me-
  и peer-пайплайны не делят состояние фильтра. Причина: одноразовый путь
  давал артефакт на каждом стыке чанков — на send-пути это ~90 стыков/сек
  (кадры тапа ~10мс). Пруф: `StreamingResamplerTests` (стыковой maxStep у
  стриминга ≤ 2× синусного bound; baseline-тест фиксирует, что one-shot путь
  его превышает).
- **`Resampler` (static, one-shot)** — прежняя семантика «каждый чанк
  независим»: cached AVAudioConverter + `.reset()` перед чанком + выравнивание
  длины. Остался для тестов/офлайн-тулов и как fallback.
- `toWire(_:targetSampleRate:)` — mic/tap → движок; оркестратор передаёт
  `TranslationStream.inputWireSampleRate` (24 kHz OpenAI, 16 kHz Gemini).
  `fromWire(_:)` — движок → speakers (вход всегда 24 kHz).

### `WireFrameBatcher` (Sources/UnisonDomain/WireFrameBatcher.swift)
Сендеры оркестратора копят wire-байты до **~100мс** перед `stream.send` —
раньше каждый ~10мс кадр тапа/мика улетал отдельным JSON+base64 WS-сообщением
(~90/сек на стрим против рекомендованных 50–100мс чанков). Бонус: реплей-
ринг (`audioBufferFrames=30`, «3с при 100мс кадрах») снова реально держит
~3с, а не 0.3с. Хвост доливается `flush()` на конце стрима.

### `PlaybackPacing` v5 — asymmetric «never slow, gently drain» (Sources/UnisonAudio/PlaybackPacing.swift)
Регулятор адаптивного TimePitch.rate. Базовый рейт = **ровно 1.0×**; рейт
**только повышается** (никогда ниже 1.0×) и **только мягко** (cap 1.06×),
чтобы слить буфер, выросший выше setpoint.

| Константа | Значение | Смысл |
|---|---|---|
| `targetBufferSec` | **1.0** (env `UNISON_BUFFER_MS`) | **Край deadband** (порог слива): пока depth ≤ него — рейт РОВНО 1.0× (TimePitch не трогает звук), сливаем только ВЫШЕ. Порог обязан быть ВЫШЕ натуральной глубины очереди: 0.5 (OpenAI natural 0.5–0.75) и 0.75 (Gemini natural 0.75–1.0, лог 2026-07-02) оба заставляли контроллер жить в непрерывном подсливе (TimePitch вечно ≠1.0) и срезать подушку перед сетевым гэпом (underrun при ws-rx 719мс). 1.0 = колено frontier (0.30→6.7% фризов, 0.60→5.2%, 1.0→3.8%, выше — плато) |
| `correctionGain` | **0.15** | `rate = 1.0 + (depth_smooth − threshold)·gain`. 0.15 (было 0.4) — слив еле заметный, не слэмит рейт |
| `maxRate` | **1.06** | Очень мягкий cap (было 1.15). 1.06 хватает обогнать доставку модели ~1.015×, но почти неслышно. 1.15 слэмил рейт и осушал очередь в 0 («вкл/выкл») |
| `minRate` | 1.0 | **Жёсткий floor: никогда не медленнее реалтайма** |
| `depthSmoothAlpha` | 0.15 | τ ≈ 0.6 с (было 0.05/τ≈2с — медленный сглаживатель был корнем микропауз) |
| `maxRateStepPerTick` | 0.05 | Slew = 0.5/сек — плавно |

**Почему v5 (был v4 «bidirectional»).** Офлайн-реплей **реального** записанного
timeline (`pacing-eval`) показал: v4 давал underrun 3% в **8 окнах** И раздувал
буфер до **~960 мс**, тогда как простой фиксированный 1.0× давал **ноль**
underrun. Виноват был **сам v4**: он целил рейт по `arrivalRateEMA + correction`
через медленный (τ≈2с) сглаживатель, поэтому на бёрсте ускорялся — **сливая
подушку прямо перед следующей паузой** (это и есть микропауза) — а floor 0.85×
растягивал звук не вовремя (артефакт «робот»). Оба симптома, на которые жаловался
юзер, — **наш контроллер**, не сеть.

**v5 реагирует только на фактический backlog.** Базовый рейт 1.0×; рейт растёт
лишь чтобы слить буфер выше `targetBufferSec`, мягко (до 1.06×), а быстрый
сглаживатель (τ≈0.6с) ловит суб-секундные бёрсты. `arrivalRateEMA` **убран из
формулы** (остался только для диагностического лога). Это убрало осцилляцию
рейта и «робота»: рейт держится в **[1.00, 1.05]×** без слышимого растяжения.

**Джиттер-буфер (`targetBufferSec`) и БАГ переслива (реальные логи 2026-06-30).**
v5 убрал осцилляцию, но **фризы остались и были заметны**. Реальный лог вскрыл
настоящую причину — **наш контроллер сам опустошал буфер**: при тонком setpoint
0.30 с он разгонялся до ~1.08×, чтобы слить *здоровый* буфер 0.5 с обратно к
0.30 — **выжигая подушку прямо перед паузой модели**, после чего плеер пустел
(фриз). Лог поймал это даже когда **модель отдавала вовремя** (gaps 199–322мс ≈
realtime, а буфер всё равно сливался 0.5→0 → UNDERRUN): тонкий setpoint заставлял
контроллер срезать подушку, которую сам же должен держать, потом underrun,
ребилд, снова срез. Это и есть «недогляд».

**Фикс:** `targetBufferSec` это теперь **потолок**, а не setpoint. Контроллер
играет 1.0× пока очередь ≤ потолка (ДЕРЖИТ подушку 0.3–0.9 с, не трогает), и
сливает только ВЫШЕ (cap runaway latency). Поднят до **1.0 с** — на реальной
сессии: фризы 6.7%→**3.8%**, тишина 2300→**1300 мс**, rate_max 1.15→**1.089×**
(почти не сливает). Frontier: 0.30→6.7%, 0.60→5.2%, 1.0→3.8%/600мс — выше 1.0
насыщается (остаток — это **продолжительные** замедления модели, где суммарный
недобор > подушки, не одиночный gap). Тюнится вживую `UNISON_BUFFER_MS` (=600
ради latency на спокойной сети, =1400 на рваной). Остаток намеренно **не**
прячем растяжением (вернёт «робота»). Следующий шаг если мало — **adaptive
jitter buffer** (растить подушку только в турбулентность, latency низкая в покое).
`pipelineFrameBuffer=50` + `bufferingOldest` гарантируют что буфер не растёт > 5 с.

### `CompensatingAGCRunner` (Sources/UnisonAudio/CompensatingAGC.swift)
Компенсация для model fade (см. выше). **Адаптивная цель:** AGC
восстанавливает приглушённый звук к **пиковому (свежему) RMS самой сессии**
(`AGCState.sessionPeakRMS`), а не к жёсткой константе — компенсация
авто-калибруется под громкость каждого движка (OpenAI ≈ 0.05, Gemini ≈ 0.12)
и под спикера/микрофон. Раньше фиксированный `targetRMS=0.05` пиннил громкие
движки (Gemini) ниже их свежего уровня → юзер всё равно слышал fade 0.12→0.05.
Цель сбрасывается на паузе (≥3 с тишины), как и сам fade модели.

| Константа | Значение | Смысл |
|---|---|---|
| `targetRMS` | 0.05 | **Floor** адаптивной цели (минимум для тихих сессий) |
| `maxGain` | 4.0 | +12 dB potential |
| `minGain` | 1.0 | Только бустим, никогда не глушим |
| `rmsTauSec` | 5.0 | τ EMA в **секундах**; per-frame α = 1−exp(−dur/τ) |
| `gainSlewPerSec` | 0.2 | Slew 0.2/**сек**, масштабируется на frameDurationSec |
| `silenceFloor` | 0.005 | Ниже — silence, не апдейтим EMA, не бустим |
| `resetSilenceSec` | 3.0 | После 3с silence — снос к начальному state |

⚠️ **Константы time-based (2026-07-02), не per-frame.** Старые
`rmsAlpha`/`gainSlewPerFrame` были откалиброваны «на 10 кадров/сек» (100мс),
а `apply()` зовётся раз на **чанк модели** (250–400мс) — компенсация
работала в 2.5–4× медленнее задуманного (юзер слышал «тише» десятки секунд,
пока гейн доползал). Тест-инвариант: одинаковый wall-clock fade чанками
100мс и 400мс даёт одинаковый гейн (`agc_compensation_isInvariantToChunkSize`).

Применяется в обоих плеерах (`AVAudioOutputMixer` для local listening, `BlackHole2chPlayer` для virtual mic).

### `AVAudioOutputMixer` (Sources/UnisonAudio/AVAudioOutputMixer.swift)
Локальное проигрывание (что слышит пользователь).

- Два player: `translatedPlayer` (vol 1.0) + `originalPlayer` (vol 0.2 настраиваемый)
- `AVAudioUnitTimePitch` между translatedPlayer и mainMixer для адаптивного rate
- Output device — `settings.outputDeviceUID` (default device если не указан)

**Seam declick (щелчки на стыках чанков).** `scheduleTranslated` рампит первые
~2мс каждого буфера от того места, где звук реально остановился: при непрерывном
проигрывании — от последнего сэмпла предыдущего буфера (маленький скачок от
resampler-reset / AGC-гейн-степа сглаживается; если сигнал уже непрерывен — рамп
≈ сигнал, no-op); при возобновлении после опустошения очереди (queue пуст /
большой schedGap) — от 0 (плеер играл цифровую тишину, первый ненулевой сэмпл
иначе щёлкает). Один корректный фикс на все случаи (resampler/AGC/resume) без
риска per-chunk DSP. Логика вынесена в **`SeamDeclick`** (общая с
`BlackHole2chPlayer`). **Аудио-pump переведён с @MainActor на detached
`.userInitiated`** — ресемпл+отдача больше не ждут рендер транскрипта/glass;
**mic-памп, peer-сплиттер и peer-сендер** тоже detached (⚠️ plain `Task {}`
внутри @MainActor-класса НАСЛЕДУЕТ изоляцию — проверено исполнением пробы на
этом тулчейне; только `Task.detached` реально уводит per-frame работу с
главного потока), health-стампы — неблокирующий Task, коалесc ≤1/0.5с.
`PlaybackPacing` пишет `timePitch.rate` только при изменении (не 10×/сек).

**Gap concealment (`GapConcealment`, 2026-07-02).** Остаточные микропаузы
(затяжные замедления модели, ~3.8% тиков — подушкой не закрываются) больше не
обрываются в цифровую тишину: после каждого реального буфера взводится вотчер
на `translatedQueueEndsAt − 20мс`; если новый буфер не пришёл — планируется
**один** синтетический буфер ~200мс: последний питч-период (автокорреляция
60–400Гц; unvoiced → 10мс блок) затухает линейно до нуля. Обрыв на полуслове
звучит как естественный спад; на границе тёрна — просто чуть более длинный
хвост. Возврат реального аудио заходит через declick-рамп от нуля. Один
conceal на dry-spell (латч до следующего реального буфера), в catch-up не
вмешивается. A/B: `UNISON_DISABLE_CONCEAL=1`. Лог: `[conceal speakers]`.
Ядро чистое (`GapConcealmentTests`); comfort noise / WSOLA — сознательно v2.

**BT/HFP-защита (2026-07-02, симптом «из-за стены» — доказан логом).**
Подключение мика BT-гарнитуры переводит её целиком в узкополосный voice-профиль
(HFP: 8–32кГц; в реальном логе выходной маршрут флипал на 16000Hz×1ch) — ВСЁ,
что слышит юзер, глохнет и тишает до возврата A2DP. Два рубежа:
`AVAudioOutputMixer.isNarrowbandRoute` (<40кГц) проверяется после каждого
configure (это и есть моменты HFP↔A2DP флипов) → `routeDegradedEvents` →
`orchestrator.outputRouteDegraded` → хинт поповера «Bluetooth-гарнитура
ухудшает звук» + лог `[route-degraded]`; и `AVAudioEngineMicrophone` при
дефолтном входе = BT-мик предпочитает **встроенный** микрофон
(`preferredMicUID`; явный выбор юзера уважается всегда).

**sched-stall — порог относителен каденции (2026-07-02).** Фиксированные
250мс были НИЖЕ естественной каденции чанков (250–400мс) → 145 ложных
срабатываний за сессию. Теперь `isSchedStall`: gap > длительность предыдущего
чанка + 150мс (floor 400мс).

> ✅ **ГИПОТЕЗА «TimePitch = источник латентности/деградаций» — ОПРОВЕРГНУТА
> измерением** (offline probe `Tests/UnisonAudioTests/TimePitchProbe.swift`,
> `UNISON_RUN_PROBES=1 swift test --filter TimePitchProbe`). На rate=1.0 (>90%
> тиков) `AVAudioUnitTimePitch` **прозрачен и добавляет НОЛЬ латентности**:
> импульс — пик не сдвинут (0мс group delay), pre/post-echo = −240дБ (тишина,
> ноль смазывания транзиента), AU сам объявляет `latency = 0`; синус — SNR 60дБ
> (шум на −60дБ, ниже маскинга голоса = неслышно). Bypass возвращает 149дБ, но
> разница неслышима. **Вывод: НЕ выпиливать TimePitch** — латентности для отыгрыша
> нет («наше преимущество» он не трогал), артефакта на unity нет, а сам он —
> механизм слива буфера. Прежний TODO про «~90мс всегда» был апокрифом (пришёл от
> research-агента, не измерялся). **Gap concealment сделан (v1, 2026-07-02)** —
> см. секцию AVAudioOutputMixer (питч-период + fade; comfort noise/WSOLA — v2).
> Осталось: **локализация «внезапных деградаций»**: модель это или наш pipeline
> (capture реального model-output через pacing-eval + numeric-scan на
> glitch/dropout/clip) — BT/HFP-кейс теперь детектится сам (`[route-degraded]`).

### `BlackHole2chPlayer` (Sources/UnisonAudio/BlackHole2chPlayer.swift)
Virtual mic для пира — выводит переведённый user audio в BlackHole 2ch, который видеоконф-app использует как мик.

- Та же node-цепочка что в outputMixer для translated path
- AGC применяется на стороне peer'а тоже
- **Паритет с колонками (2026-07-02):** catch-up `admit()` (раньше после
  сетевого бёрста пир слушал многосекундно-устаревший перевод без ресинка),
  seam declick через общий `SeamDeclick`, и `reset()` вместо
  `player.stop()` в `stop()` (тот же wedge-фикс, что в mixer: flush
  completion-хендлеров клинит coreaudiod при активном Process Tap — а
  `.call`, единственный режим этого плеера, всегда с тапом)

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

### 🔥 Известный баг — нет звука после подключения BT в середине сессии

**Симптом:** запускаешь Unison с выключенными BT-наушниками, потом
подключаешь их — звук пропадает, помогает только перезапуск приложения.

**Корневая причина (воспроизведена в VM детерминированно):** подключение
BT меняет **дефолтное устройство вывода**, и `AVAudioEngine` на это
**сам останавливает** свой граф, постит `AVAudioEngineConfigurationChange`
и ждёт, что владелец пересоберёт и перезапустит движок. Мы нотификацию
нигде не слушали → движок вывода стоял на устаревшем устройстве → тишина.
Захват (Process Tap, tap-only aggregate) от устройства вывода не зависит,
поэтому транскрипт продолжал идти — молчал именно звук. Воспроизводится
без реального BT флипом nominal sample rate дефолтного выхода — та же
`ConfigurationChange` (`scripts/vm-repro-devicechange.sh`,
`Tools/TapBenchmark/ReproDeviceChange.swift`): до фикса `isRunning=false`
после смены, после фикса `isRunning=true` (self-healed).

**Фикс — self-heal через [[DebouncedNotificationObserver]]:** каждый
аудио-движок слушает свою нотификацию и при срабатывании пересобирает граф
и перезапускается (с дебаунсом — одна смена устройства постит пачку
нотификаций):

- `AVAudioOutputMixer` (динамики) и `BlackHole2chPlayer` (вывод в call) →
  `AVAudioEngineConfigurationChange`. Реконфиг переприменяет привязку
  устройства (`nil` = следовать новому дефолту — кейс BT), пересоединяет
  граф, `engine.start()`, `players.play()`, заново инициализирует pacing.
  `reset()` плееров перед реконфигом — чтобы flush `.dataPlayedBack` не
  завис (тот же механизм, что в Stop-фиксе).
- `AVAudioEngineMicrophone` (захват с микрофона) построен на
  **AVCaptureSession**, не AVAudioEngine, поэтому слушает
  `AVCaptureSessionRuntimeError` (обрыв устройства входа) → переразрешает
  устройство (фолбэк на системный дефолт входа, если привязанное исчезло),
  переконфигурирует сессию и перезапускает, сохраняя тот же `continuation`.

`engineLock` / `lifecycleLock` в каждом классе сериализуют self-heal со
`start`/`stop`, а флаг `started`/`running` гасит нотификацию, прилетевшую
после остановки.

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
| `UNISON_BUFFER_MS=1000` | Потолок джиттер-буфера (`PlaybackPacing.targetBufferSec`) в мс. Контроллер держит подушку ≤ него, сливает выше. Default **1000** (колено frontier; 0.75 был ниже натуральной глубины Gemini → постоянный подслив) |
| `UNISON_MAX_LATENCY_MS=2500` | Потолок catch-up (`PlaybackPacing.catchUpCeilingSec`): backlog выше него → дроп кадров до `catchUpFloorSec` (0.5с), ресинк к live |
| `UNISON_DISABLE_CONCEAL=1` | Выключить gap concealment (A/B замер сырого underrun-пола) |
| `UNISON_VAD_SILENCE_MS=300` | **Gemini VAD `silenceDurationMs`** — сколько модель ждёт тишину перед концом тёрна. API default ~800мс = и был источник фризов. Default **300**. Меньше = плавнее/меньше latency, но риск рубить тёрн в середине клаузы (хуже связность перевода) |
| `UNISON_FORCE_STATE=...` | Snapshot/harness mode forcings |

Пример полной диагностической запуска:
```bash
killall Unison
UNISON_DUMP_SENT_WAV=/tmp/sent.wav \
UNISON_DUMP_WIRE_WAV=/tmp/wire.wav \
UNISON_DUMP_PLAYBACK_WAV=/tmp/playback.wav \
open /Applications/Unison.app
```

### Always-on instrumentation (логи в `~/Library/Logs/Unison/unison.log`)

Чтобы диагностировать микропаузы **только по логам**, каждая граница output-пути
всегда пишет диагностику (мы в разработке — пусть пишут максимально подробно).
Читаются слева-направо вдоль пути «модель → колонки»:

| Тег | Где | Что показывает |
|---|---|---|
| `[ws-rx]` | URLSessionWSClient | Gap между WS-фреймами **на сокете** (>400мс), ДО актора/декода — истинная сетевая/модельная каденция. Если `[ws-rx]` гладкий, а `[audio-rx]` рваный → проблема в нашем актора |
| `[turn <speaker>]` | Gemini stream | `turnComplete` — модель закончила тёрн (дальше пауза = VAD `silenceDurationMs`). Коррелирует большой `[audio-rx]` gap с границей тёрна |
| `[audio-rx <speaker>]` | Gemini/OpenAI stream | Меж-чанковый gap (+Nms) и размер чанка, на акторе. Сверять с `[ws-rx]` |
| `[pump <speaker>]` | TranslationOrchestrator | Длительность per-frame MainActor-hop'а; пишется только если >30мс = UI-конжешн тормозит audio-pump |
| `[pipeline DROP …]` | TranslationOrchestrator | `resampled`-буфер переполнен, кадр **выброшен** (downstream-плеер не успевает) |
| `[sched speakers]` | AVAudioOutputMixer | `schedGap` — wall-clock между подачами кадров в плеер (debug); `[sched-stall]` если >250мс |
| `[speakers] pacing …` | PlaybackPacing tick | depth/depth_smooth/arrival_ema/rate раз в 1с — авторитетная глубина очереди (по реальным completion-callback'ам) |
| `[UNDERRUN speakers]` | PlaybackPacing tick | **Очередь пуста посреди речи** = слышимая микропауза (авторитетный сигнал). Кросс-ссылка на теги выше локализует причину |

**Как читать при микропаузе:** найти `[UNDERRUN speakers]` → посмотреть
непосредственно перед ним: был ли большой `[audio-rx]` gap (сеть/модель)? был ли
`[pump]` >30мс (UI)? был ли `[sched-stall]` (pipeline)? `[pipeline DROP]`
(back-pressure)? — это и есть корень конкретной паузы.

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

# Full-chain: прогнать model-output WAV через НАСТОЯЩИЙ AVAudioOutputMixer
# (реальные AGC + declick + timePitch + scheduling, реальные стыки чанков),
# дамп post-chain через UNISON_DUMP_PLAYBACK_WAV. A/B клика: UNISON_DISABLE_DECLICK=1.
swift run pacing-eval --audio /path/to/model-output.wav --full-chain-render --output ./out
UNISON_DISABLE_DECLICK=1 swift run pacing-eval --audio /path/to/model-output.wav --full-chain-render --output ./out
```

### Автономная проверка щелчков / артефактов (без юзера)

«Щелчки на стыках» и «внезапные деградации» проверяются **без прослушивания**:

1. **`Tests/UnisonAudioTests/DeclickTests.swift`** — детерминированный юнит-пруф,
   что `AVAudioOutputMixer.declickSeam` гасит стык: resume-from-silence 0.6→<0.02,
   AGC/resampler-step 0.9→<0.03 (≥10×), no-op когда уже непрерывно. Гоняется в CI/VM.
2. **`--full-chain-render`** (выше) — прогон реального выхода модели через **реальный**
   микшер; A/B `UNISON_DISABLE_DECLICK` доказал на живом Gemini RU→EN, что declick
   вдвое режет худший sample-step (0.50→0.28) и число click-scale шагов (30→16).
3. **`scripts/analyze_audio.py <wav> [label]`** — numpy-сканер WAV (int16 **и** float32-
   дампов) на glitch/dropout/RMS-jump/clip/fade. Калибруй против natural speech.
   `TimePitchProbe.swift` (gate `UNISON_RUN_PROBES=1`) — latency/fidelity замер узлов.

> ✅ `BlackHole2chPlayer` (peer/virtual-mic путь) с 2026-07-02 имеет тот же
> seam declick (общий `SeamDeclick`) и catch-up гейт, что и speakers-путь.
> Gap concealment на peer-пути пока нет (v2).

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

- [x] Минимальное repro для bug report провайдерам (fade — есть и у OpenAI, и у Gemini) — `scripts/fade-minrepro.sh` + черновик `docs/fade-bug-report-draft.md`; прогнать вживую и отправить
- [x] **Громкость деградирует (fade)** — компенсируется адаптивным AGC (цель = peak RMS сессии, авто-калибровка под движок: OpenAI ≈ 0.05, Gemini ≈ 0.12)
- [x] **«Звук резко пропадает и появляется» + «роботизированный»** — оба симптома были **наш v4 контроллер**: `arrivalRateEMA + correction` через медленный (τ≈2с) сглаживатель ускорялся на бёрсте и сливал подушку перед паузой (underrun 3%/8 окон, пик буфера 963мс), а floor 0.85× растягивал звук («робот»). Доказано офлайн-реплеем реального timeline. Чинит `PlaybackPacing` **v5** (asymmetric: `1.0 + correction`, никогда < 1.0×, мягкий cap 1.15×, τ≈0.6с) → underrun 0.8% (1 окно), пик 550мс, рейт [1.00,1.05]×, mean latency без изменений
- [x] **Заметные фризы — настоящая причина: БАГ переслива (наш контроллер).** Live-тест с ключом юзера (pacing-eval, 3 прогона ru→en через прод-стрим) расставил всё по местам: внутри речи p99 меж-чанковых gap'ов = **428–489мс**, а МАКС gap (0.54–0.87с) всегда на **хвосте реплики** (t≈39с, ПОСЛЕ конца 32.7с инпута), не в середине. `[ws-rx]` (socket-level) подтвердил: gap'ы на **сети/модели**, до нашего актора — не наш пайплайн. Значит держимая подушка 500мс покрывает речь; фризы были от **переслива** (контроллер сливал подушку → underrun даже на нормальных 250–489мс gap'ах). Фикс переслива (`targetBufferSec` = потолок) + 500мс = гладко внутри речи
- [x] **VAD-гипотеза оказалась НЕВЕРНОЙ** (важно, чтобы не повторять). Live A/B `silenceDurationMs` 300 vs 800 → почти идентично (p50 ~248, max 764 vs 980). На монологе VAD не влияет на каденцию (нет границ тёрнов). `realtimeInputConfig` оставлен как возможная оптимизация latency для реальных диалогов (env `UNISON_VAD_SILENCE_MS`), но это **НЕ** фикс фризов
- [ ] Подтвердить на слух (юзер) что 500мс + фикс переслива = гладко. Хвостовые gap'ы (конец реплики) и паузы спикера — натуральные, не фриз. Если в реальном звонке turn-boundary паузы мешают — тюнить `UNISON_VAD_SILENCE_MS` и слушать связность перевода
- [ ] `[UNDERRUN speakers]` недосчитывает фризы при хронически тонком буфере (guard `depth_smooth>0.03`) — `[sched-stall]` надёжнее как прокси фриза
- [ ] Деградация *качества* модели (не громкости, бустом не лечится) — отдельное расследование / репорт провайдеру
- [x] Per-frame MainActor hop в pump'ах оркестратора — закрыт полностью (2026-07-02): output-пампы (PR #15), mic-памп/peer-сплиттер/peer-сендер (`Task.detached` — plain `Task {}` наследует @MainActor, доказано пробой в ревью PR #16; блокирующий `MainActor.run` → неблокирующий коалесц. хоп ≤1/0.5с)
- [x] **Gap concealment v1** (2026-07-02) — питч-период + линейный fade ~200мс, один на dry-spell; comfort noise / WSOLA / peer-путь — v2
- [x] **BT/HFP «из-за стены»** (2026-07-02) — корень доказан логом (выход 16000Hz×1ch); детект `isNarrowbandRoute` + хинт в поповере + предпочтение встроенного мика при BT-дефолте
- [ ] Concealment на peer-пути (`BlackHole2chPlayer`) — v2, если пир жалуется на микропаузы
- [ ] Подтвердить на слух: потолок 1.0с + concealment + streaming resampler = гладко (лог-маркеры: `[conceal speakers]` появляется на гэпах, `[UNDERRUN]` реже, `[sched-stall]` только на настоящих стволах)

---

*Last updated: 2026-07-02*
