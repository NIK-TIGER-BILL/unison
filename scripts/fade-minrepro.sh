#!/usr/bin/env bash
# Minimal reproduction of the progressive output-amplitude fade in realtime
# translation engines (both OpenAI gpt-realtime-translate and Gemini
# gemini-3.5-live-translate-preview exhibit it — see
# docs/fade-bug-report-draft.md for the write-up this script feeds).
#
# What it does: runs ONE real session through the production stream via the
# pacing-eval harness with amplitude-stable synthesized speech, dumping both
# directions:
#   sent.wav — what the client sent (must be amplitude-stable → our side OK)
#   wire.wav — what the engine returned (fades over the session → their side)
# then scans both with the numeric analyzer and prints per-quartile RMS.
#
# Usage:
#   scripts/fade-minrepro.sh [openai|gemini] [input.wav] [outdir]
# Requires the engine API key in the keychain (same entry the app uses) or
# in OPENAI_API_KEY / GEMINI_API_KEY. Costs one short realtime session.
set -euo pipefail
cd "$(dirname "$0")/.."

PROVIDER="${1:-openai}"
AUDIO="${2:-Tests/Fixtures/audio/ru-monologue-normal.wav}"
OUT="${3:-/tmp/unison-fade-minrepro-$PROVIDER}"
mkdir -p "$OUT"

if [[ ! -f "$AUDIO" ]]; then
    echo "input WAV not found: $AUDIO (generate with: bash Tests/Fixtures/audio/generate.sh)" >&2
    exit 1
fi

case "$PROVIDER" in
openai)
    export OPENAI_API_KEY="${OPENAI_API_KEY:-$(security find-generic-password -s "com.unison.app" -a "openai-api-key" -w)}"
    ;;
gemini)
    export GEMINI_API_KEY="${GEMINI_API_KEY:-$(security find-generic-password -s "com.unison.app" -a "gemini-api-key" -w)}"
    ;;
*)
    echo "unknown provider: $PROVIDER (openai|gemini)" >&2
    exit 1
    ;;
esac

echo "=== fade min-repro: $PROVIDER, input=$AUDIO → $OUT ==="
UNISON_DUMP_SENT_WAV="$OUT/sent.wav" \
UNISON_DUMP_WIRE_WAV="$OUT/wire.wav" \
    swift run -c release pacing-eval \
        --provider "$PROVIDER" --audio "$AUDIO" --target ru \
        --runs 1 --output "$OUT"

echo
echo "=== client → engine (must be amplitude-stable) ==="
python3 scripts/analyze_audio.py "$OUT/sent.wav" "sent"
echo
echo "=== engine → client (the fade shows up here) ==="
python3 scripts/analyze_audio.py "$OUT/wire.wav" "wire"
echo
echo "Artifacts in $OUT — attach sent.wav + wire.wav + the RMS CSVs to the report."
