# GitHub Release Pipeline — Design

- **Date:** 2026-06-17
- **Status:** Approved — implementing
- **Scope:** Make "everything for release through GitHub" actually work for
  Unison, with graceful signing/notarization degradation.

## Context / problem

Unison is a SwiftPM macOS 26 (Tahoe) menubar app. Distribution is **direct**
(Developer ID + notarization + DMG), **not** the Mac App Store — the app
installs the BlackHole audio driver under an admin prompt, taps process audio,
and switches the system default output device, all of which the App Store
sandbox forbids.

The existing release infrastructure is broken/incomplete (verified
2026-06-17):

- Both `.github/workflows/ci.yml` and `release.yml` run on `macos-14` +
  `Xcode 16`, which cannot build a `swift-tools-version:6.2` / macOS 26 SDK
  project. (macOS 26 GitHub runners are GA since 2026-02-26, label `macos-26`.)
- App version is hardcoded in `Resources/Info.plist` (`1.0` / `1`); not derived
  from the release tag.
- `scripts/build_release.sh` hard-requires signing secrets (`:?`) → fails
  without them; no path to exercise the pipeline before an Apple account exists.
- DMG is bare `hdiutil` output — no `/Applications` drop target.
- `docs/qa/release-checklist.md` references macOS 14; no Gatekeeper validation.
- Repo `NIK-TIGER-BILL/unison`: 0 tags, 0 releases, 0 secrets → the pipeline has
  never run.

## Goals

1. `git tag vX.Y.Z && git push --tags` → GitHub Actions builds, signs (if
   secrets), notarizes (if secrets), staples, packs a DMG, and publishes a
   GitHub Release with auto-generated notes + a SHA256 checksum.
2. Green CI (build + test + lint + bundle smoke) on macOS 26.
3. App version derived from the tag.
4. **Graceful degradation:** no secrets → ad-hoc DMG (testable); secrets present
   → signed + notarized DMG. No code change to flip between them.
5. Documented setup: secrets, certificate generation, release procedure,
   Gatekeeper verification.

## Non-goals (this phase)

- Sparkle auto-updates (deferred; pipeline emits a stable per-release DMG URL so
  it can be layered on later).
- Mac App Store (architecturally closed).
- Fastlane / Xcode-project migration (keep SwiftPM + dependency-free shell
  scripts — matches the project's deliberate design).
- DMG background artwork (a functional `/Applications` symlink is enough).

## Approach

Evolve the existing shell scripts + workflows (**Approach A**).

- **Rejected B — `xcodebuild archive` + `exportArchive`:** the Apple-canonical
  path, but requires introducing project generation and fights the project's
  intentional SwiftPM-only setup.
- **Rejected C — Fastlane:** industry standard but adds Ruby + a toolchain the
  project deliberately avoids; the shell scripts are transparent and already
  90% there.

## Design

### Versioning

The git tag is the single source of truth:

| Field | Value | Source |
| --- | --- | --- |
| `CFBundleShortVersionString` | `1.2.3` | tag minus the `v` prefix |
| `CFBundleVersion` | commit count | `git rev-list --count HEAD` (monotonic) |

Stamped into the **copied** `Info.plist` at bundle time via `PlistBuddy`; the
repo's `Resources/Info.plist` stays a template (placeholder `1.0` / `1`). Local
builds without the env vars keep the placeholders. Tags must be semver
(`vMAJOR.MINOR.PATCH`).

### `scripts/bundle_app.sh`

After copying `Info.plist` into the bundle and **before** `codesign` (signing
seals the bundle), stamp `CFBundleShortVersionString` / `CFBundleVersion` from
`MARKETING_VERSION` / `BUILD_VERSION` when those env vars are set. Keep the
existing Developer ID vs ad-hoc signing branch.

### `scripts/build_release.sh`

- Make all four credentials optional (`${VAR:-}`, no `:?`).
- Notarize + staple **only** when `DEVELOPER_ID` + `APPLE_ID` + `APP_PASSWORD` +
  `TEAM_ID` are all non-empty; otherwise print a clear "unnotarized" warning and
  continue.
- Pack the DMG from a staging dir containing the app + an `/Applications`
  symlink (drag-to-install), always.
- Emit `build/Unison.dmg.sha256`.

### `.github/workflows/release.yml`

- Trigger: `push: tags: ['v*']`. `runs-on: macos-26`,
  `permissions: contents: write`.
- `actions/checkout@v4` with `fetch-depth: 0` (stable commit-count build number).
- `maxim-lobanov/setup-xcode@v1` with `xcode-version: '26'`.
- Map the six secrets → job `env`.
- Derive `MARKETING_VERSION` (`${GITHUB_REF_NAME#v}`) + `BUILD_VERSION`
  (`git rev-list --count HEAD`) into `$GITHUB_ENV`.
- "Import signing certificate" step gated `if: env.CERT_P12_BASE64 != ''`:
  ephemeral keychain (random password) in `$RUNNER_TEMP`, import `.p12`,
  `set-key-partition-list`, set default + unlock.
- "Build release" runs always → `scripts/build_release.sh` (degrades on its own).
- "Publish" via `softprops/action-gh-release@v2` with
  `generate_release_notes: true`, files = DMG + `.sha256`.
- "Clean up keychain" `if: always() && env.CERT_P12_BASE64 != ''`.

### `.github/workflows/ci.yml`

- `runs-on: macos-26` + `setup-xcode@v1` `'26'` for all jobs.
- `build-test`: `swift build`, `swift test --parallel`, then an ad-hoc
  bundle smoke (`CONFIG=debug ./scripts/bundle_app.sh` + verify the executable
  exists and `codesign -dv` succeeds) folded into the same job to avoid a third
  (10×-cost) macOS runner.
- `lint`: unchanged except runner/Xcode.

### Docs

- `docs/release.md` (**new**): release procedure, secrets table, Developer ID
  certificate generation + `.p12` export + app-specific password steps,
  graceful-degradation explanation, Gatekeeper verification.
- `docs/qa/release-checklist.md`: macOS 14 → 26; add `spctl -a -vvv -t install`,
  `xcrun stapler validate`, and a browser-download quarantine test.

### Required GitHub secrets (documented, never committed)

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID` | `Developer ID Application: Name (TEAMID)` codesign identity |
| `CERT_P12_BASE64` | base64 of the exported cert + private key (`.p12`) |
| `CERT_PASSWORD` | `.p12` export password |
| `APPLE_ID` | Apple ID email for `notarytool` |
| `APP_PASSWORD` | app-specific password for `notarytool` |
| `TEAM_ID` | 10-char Apple Developer Team ID |

Absent/empty secrets → ad-hoc artifact (graceful).

## Verification plan

- `bash -n` on both scripts.
- Run `bundle_app.sh` locally (ad-hoc) with `MARKETING_VERSION` / `BUILD_VERSION`
  set; assert the stamped `Info.plist` values and that `codesign -dv` succeeds.
- Parse both workflow YAMLs (`python3 -c 'yaml.safe_load(...)'`; `actionlint` if
  available).
- GitHub Actions itself can't run locally; the shell scripts (the real risk
  surface) are verified locally.

## Rollout (first release)

1. (For public distribution) enroll in the Apple Developer Program, create a
   Developer ID Application certificate, export the `.p12`, generate an
   app-specific password.
2. Add the six secrets to the repo.
3. `git tag v1.0.0 && git push origin v1.0.0`.
4. Watch Actions → a GitHub Release with the notarized DMG appears.

Without steps 1–2, tagging still produces an ad-hoc DMG for testing.
