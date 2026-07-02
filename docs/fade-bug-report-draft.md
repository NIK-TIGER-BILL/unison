# Bug report draft — progressive output-amplitude fade in realtime translation

Черновик для отправки провайдерам (OpenAI + Google). Данные собраны нашим
харнессом; перед отправкой прогнать свежий мин-репро
(`scripts/fade-minrepro.sh openai` / `gemini`) и приложить его артефакты.
Статус: **draft, не отправлен**.

---

## For OpenAI (gpt-realtime-translate)

**Title:** `gpt-realtime-translate` progressively attenuates its own output
amplitude over continuous sessions (−56…66 % over ~25 s, resets after ~3 s of
input silence)

**Endpoint:** `wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate`

**Summary.** On a continuous session with amplitude-stable input speech, the
translated audio the model returns gets progressively quieter. Measured over
~25 s of continuous synthesized speech (input RMS stable at 0.05–0.07,
slope ≈ 0): output RMS falls from ≈ 0.05 (first quartile of the session) to
≈ 0.015 (fourth quartile) — a 56–66 % drop. After an input pause of ≥ ~3 s
the next utterance starts at full level again, i.e. some per-session state
resets on silence.

**What we ruled out on our side:**

- Input amplitude drift — the dumped wire-format input (`sent.wav`) is
  RMS-stable for the whole session.
- `noise_reduction` settings — `near_field`, `far_field` and explicit `null`
  all show the same fade.
- Client-side resampling/buffering — the fade is present in the raw base64
  audio deltas as received from the socket, before any client processing.

**Repro.** Stream ~30 s of continuous speech (no pauses > 2 s) as 100 ms
24 kHz int16 chunks; collect `response.output_audio.delta` payloads; compute
per-second RMS of the concatenated output. Expected: roughly flat. Actual:
monotonic decay to ~⅓ of the initial level. Attached: `sent.wav` (input),
`wire.wav` (output), per-second RMS CSV.

**Impact.** Real-time translation apps have to ship client-side compensating
AGC; beyond amplitude, long sessions also degrade in *timbre* (muffled), which
gain compensation cannot fix.

**Ask.** Confirm whether this is intended behavior (e.g. an internal AGC /
self-monitoring loop) and whether a session option can disable it.

---

## For Google (gemini-3.5-live-translate-preview)

**Title:** `gemini-3.5-live-translate-preview` output amplitude decays over
continuous translation sessions (resets on input silence)

**Endpoint:** `BidiGenerateContent` WebSocket, model
`models/gemini-3.5-live-translate-preview`, `translationConfig` +
`responseModalities: ["AUDIO"]`.

**Summary.** Same shape as above: with amplitude-stable 16 kHz input, the
24 kHz output audio's RMS decays over tens of seconds of continuous
translation (fresh-session level ≈ 0.12 → noticeably lower by the end of a
long utterance stream), recovering after a few seconds of input silence.

**Repro.** As above, via `realtimeInput.audio` 100 ms chunks;
`serverContent.modelTurn.parts[].inlineData` audio concatenated and analyzed
per second. Attach fresh `sent.wav` / `wire.wav` / RMS CSV from
`scripts/fade-minrepro.sh gemini`.

**Ask.** Same: intended or bug; per-session switch to disable.

---

## Наши компенсации (для контекста, в репорт не включать)

- `CompensatingAGCRunner` — адаптивная цель = пиковый RMS сессии, слив
  0.2/с (time-based), floor 0.05, cap ×4. Возвращает громкость, но не тембр.
- Открытый вопрос — спектральная деградация на длинных сессиях
  («глухой» звук): бустом не лечится, нужен фикс на стороне модели.
