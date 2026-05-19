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
```

See `docs/superpowers/specs/2026-05-19-unison-design.md` for the design doc and
`docs/superpowers/plans/2026-05-19-unison.md` for the implementation plan.
