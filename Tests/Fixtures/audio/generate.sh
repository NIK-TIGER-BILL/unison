#!/bin/bash
# Generate test audio fixtures for pacing-eval via macOS `say`.
#
# Output: 24kHz int16 mono WAV files matching the wire format OpenAI's
# Realtime Translate API expects. Saved next to this script.
#
# Run from anywhere:
#   bash Tests/Fixtures/audio/generate.sh

set -euo pipefail
cd "$(dirname "$0")"

# Russian: medium-paced 30s monologue. Yuri is the standard Russian voice
# on macOS — present in default install since at least macOS 13.
RU_TEXT="Сегодня мы рассматриваем интересную задачу: как сделать так, чтобы перевод речи в реальном времени звучал плавно, без неприятных задержек между словами. Сначала кажется, что задача простая — модель отдаёт аудио, мы его проигрываем. Но на практике поток приходит с переменной скоростью, и это создаёт проблемы. Сегодня мы разберём, как с этим бороться."

# English: medium-paced 30s monologue. Daniel is the standard British
# English voice on macOS.
EN_TEXT="Today we are looking at an interesting problem: how to make real-time speech translation sound smooth, without uncomfortable pauses between words. At first it seems simple — the model emits audio, we play it back. But in practice, the stream arrives at variable speeds, which creates real engineering problems. Today, we will examine how to deal with this."

# English: fast-paced for testing speedup behaviour.
EN_FAST_TEXT="The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog."

generate() {
    local out_basename="$1"
    local voice="$2"
    local rate="$3"
    local text="$4"

    local aiff_path="${out_basename}.aiff"
    local wav_path="${out_basename}.wav"

    echo "[gen] ${out_basename} (voice=${voice}, rate=${rate})"
    say -v "${voice}" -r "${rate}" -o "${aiff_path}" "${text}"
    # Convert to 24 kHz int16 mono WAV (the OpenAI Realtime wire format).
    afconvert -f WAVE -d LEI16@24000 -c 1 "${aiff_path}" "${wav_path}"
    rm -f "${aiff_path}"

    # Print duration for sanity-check.
    local duration_sec
    duration_sec=$(afinfo "${wav_path}" 2>/dev/null | grep "estimated duration" | awk '{print $3}')
    echo "[gen]   → ${wav_path} (${duration_sec}s)"
}

generate "ru-monologue-normal"  "Yuri"   180 "${RU_TEXT}"
generate "en-monologue-normal"  "Daniel" 180 "${EN_TEXT}"
generate "en-monologue-fast"    "Daniel" 280 "${EN_FAST_TEXT}"

echo "[gen] done. Fixtures in $(pwd)"
ls -la *.wav
