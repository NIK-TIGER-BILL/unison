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

### Running without a real BlackHole install

The bundled `.pkg` resources under `Resources/blackhole/` are not in the
repo. To exercise the onboarding / settings flows end-to-end without
prompting for the admin password (and without an actual driver
install), set `UNISON_DEV_MODE=1`:

```bash
UNISON_DEV_MODE=1 swift run Unison
```

In dev mode the `BundledBlackHoleInstaller` is replaced by an
in-process mock that "installs" after a ~1.5s delay — both `is2chInstalled()`
and `is16chInstalled()` then report `true`, so the onboarding flow
advances and you can sanity-check the rest of the app.

See `docs/superpowers/specs/2026-05-19-unison-design.md` for the design doc and
`docs/superpowers/plans/2026-05-19-unison.md` for the implementation plan.
