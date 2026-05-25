#!/usr/bin/env bash
# Generate Tests/Fixtures/test_speech_ru.wav — synthesized Russian
# speech at 24 kHz mono int16. Used by the VM integration test as
# the `UNISON_TEST_AUDIO` payload (FileMicrophoneCapture decodes
# this and emits frames matching the OpenAI wire format).
#
# AVSpeechSynthesizer.write(_:) is unreliable from a `swift` script
# invocation on macOS Tahoe (silently produces no buffers), so we
# shell out to the stable `say` + `afconvert` pair instead.

set -euo pipefail

OUT="Tests/Fixtures/test_speech_ru.wav"
TMP_AIFF="$(mktemp -t test_speech_XXXXXX).aiff"
TEXT="Привет, это тестовая запись для проверки перевода в Unison. Сегодня хорошая погода и мы пишем код."
VOICE="${VOICE:-Milena}"

mkdir -p Tests/Fixtures

trap 'rm -f "$TMP_AIFF"' EXIT

echo "Synthesizing via 'say' (voice=$VOICE)…"
say -v "$VOICE" -o "$TMP_AIFF" "$TEXT"

echo "Transcoding to 24 kHz mono int16 WAV → $OUT"
afconvert -f WAVE -d LEI16@24000 -c 1 "$TMP_AIFF" "$OUT"

echo "Done."
afinfo "$OUT" | sed -n '1,8p'
