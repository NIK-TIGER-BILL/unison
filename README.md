# Unison

Real-time двунаправленный голосовой переводчик для macOS.

- Микрофон: RU → любой язык
- Динамики: любой язык → RU

Снимает языковые барьеры в живом общении.

## Development

Requirements: macOS 14+, Swift 6.0+ (Command Line Tools or Xcode 16+).

```bash
# Build all targets
swift build

# Run tests (use wrapper on Command Line Tools-only machines)
./scripts/test.sh

# On a machine with full Xcode.app installed, bare swift test also works:
swift test

# Run a single test target
./scripts/test.sh --filter UnisonDomainTests

# Run only the snapshot suite (visual regression PNGs)
./scripts/test.sh --filter UnisonUITests

# (Re)record snapshots — overwrites every PNG under __Snapshots__/
RECORD_SNAPSHOTS=1 ./scripts/test.sh --filter UnisonUITests
```

### Running in dev mode (mocked Process Tap)

Process Tap audio capture requires TCC permissions that may prompt for auth.
To exercise the onboarding / settings flows end-to-end without these prompts,
set `UNISON_DEV_MODE=1`:

```bash
UNISON_DEV_MODE=1 swift run Unison
```

In dev mode the `ProcessTapCapture` is replaced by a synthetic audio source
that plays predefined sine-wave test signals. The onboarding flow advances
normally, and you can sanity-check the rest of the app.

See `docs/superpowers/specs/2026-05-19-unison-design.md` for the design doc and
`docs/superpowers/plans/2026-05-19-unison.md` for the implementation plan.
