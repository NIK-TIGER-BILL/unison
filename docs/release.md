# Releasing Unison

Unison ships **directly** — Developer ID + notarization + a DMG on GitHub
Releases — **not** through the Mac App Store. The app installs the BlackHole
audio driver under an admin prompt, taps process audio, and switches the system
default output device; all three are incompatible with the App Store sandbox.

## TL;DR — cut a release

```sh
git tag v1.0.0
git push origin v1.0.0
```

The `Release` workflow ([.github/workflows/release.yml](../.github/workflows/release.yml))
builds on a macOS 26 runner, signs + notarizes (when secrets are configured),
packs a DMG, and publishes a GitHub Release with auto-generated notes, the
`Unison.dmg`, and its `.sha256`.

## Versioning

The git tag is the single source of truth — no manual `Info.plist` edits:

| Field | Value | Source |
| --- | --- | --- |
| `CFBundleShortVersionString` | `1.0.0` | tag minus the `v` prefix |
| `CFBundleVersion` | commit count | `git rev-list --count HEAD` (monotonic) |

These are stamped into the bundled `Info.plist` at build time; the repo's
[Resources/Info.plist](../Resources/Info.plist) keeps placeholder values
(`1.0` / `1`). Tags must be semver: `vMAJOR.MINOR.PATCH`.

## Signing & notarization — graceful degradation

The pipeline runs with or without an Apple Developer account:

- **No secrets** → ad-hoc-signed DMG. Runnable for testing, but Gatekeeper warns
  end users. Fine for personal / tester builds.
- **All secrets present** → Developer ID-signed, hardened-runtime, notarized,
  stapled DMG. Double-click-to-run for end users.

Switching between the two is just adding the secrets — no code change.

## Required GitHub secrets

Set under **Settings → Secrets and variables → Actions**:

| Secret | What it is | Where to get it |
| --- | --- | --- |
| `DEVELOPER_ID` | `Developer ID Application: Your Name (TEAMID)` | Keychain Access → the certificate's name |
| `CERT_P12_BASE64` | base64 of the exported `.p12` (cert + private key) | see below |
| `CERT_PASSWORD` | password set when exporting the `.p12` | you choose it at export |
| `APPLE_ID` | Apple ID email of the developer account | — |
| `APP_PASSWORD` | app-specific password for `notarytool` | appleid.apple.com → Sign-In & Security → App-Specific Passwords |
| `TEAM_ID` | 10-char Apple Developer Team ID | developer.apple.com → Membership |

### Generating the Developer ID certificate (one-time)

1. Enroll in the **Apple Developer Program** ($99/yr) if you haven't.
2. Xcode → Settings → Accounts → your team → **Manage Certificates** → **+** →
   **Developer ID Application**. (Or create it on developer.apple.com →
   Certificates.)
3. In **Keychain Access**, find `Developer ID Application: …`, expand it so the
   private key is included, right-click → **Export 2 items…** → save as
   `cert.p12` with a password.
4. Encode it for the secret:
   ```sh
   base64 -i cert.p12 | pbcopy
   ```
   Paste into `CERT_P12_BASE64`; put the export password into `CERT_PASSWORD`.
5. App-specific password: appleid.apple.com → Sign-In & Security →
   App-Specific Passwords → generate → put into `APP_PASSWORD`.

## Local release build

```sh
DEVELOPER_ID="Developer ID Application: …" \
APPLE_ID="you@example.com" APP_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
TEAM_ID="ABCDE12345" \
MARKETING_VERSION=1.0.0 BUILD_VERSION="$(git rev-list --count HEAD)" \
./scripts/build_release.sh
```

Omit the credentials for an ad-hoc DMG. The artifact lands at `build/Unison.dmg`.

## Post-release verification

On a clean macOS 26 (Tahoe) machine/VM, run
[docs/qa/release-checklist.md](qa/release-checklist.md). Quick Gatekeeper check:

```sh
spctl -a -vvv -t install build/Unison.app   # → accepted, source=Notarized Developer ID
xcrun stapler validate build/Unison.app     # → The validate action worked!
```

## Not in scope yet

- **Auto-updates (Sparkle).** Each release already exposes a stable DMG URL;
  wiring Sparkle later means adding the SPM dependency, an EdDSA-signed
  `appcast.xml`, and the in-app updater.
- **Mac App Store.** Architecturally closed — driver install + process tap +
  device switching are sandbox-incompatible.
