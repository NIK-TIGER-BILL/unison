<div align="center">

<img src="docs/images/icon.png" width="120" height="120" alt="Unison app icon">

# Unison

### Real-time voice translation for video calls

You speak your language — your peer hears theirs. They reply — you hear yours.
Unison sits in your menu bar and translates both directions of a live call,
in real time, so the conversation just flows.

[![macOS 26 Tahoe](https://img.shields.io/badge/macOS-26%20Tahoe-000000?logo=apple&logoColor=white)](https://www.apple.com/macos/)

<br>

<img src="docs/images/transcript.png" alt="Unison live transcript — original and translated bubbles for both speakers" width="840">

</div>

---

## What it does

- **Both directions, live.** Your peer's voice is translated into your language and
  played to you; your voice is translated into theirs and fed into a virtual
  microphone — so they hear you in their language, with nothing to install on their end.
- **Works with any call app.** Zoom, Google Meet, Teams, FaceTime — anything that lets
  you pick a microphone.
- **Live transcript.** A floating glass window shows both sides, original and translation.
- **Hear the original underneath.** The untranslated voice plays quietly under the
  translation, so the call still feels human.
- **Menu-bar native.** No Dock icon, no clutter. Start, stop, and the transcript are a
  hotkey away.

## Languages

Choose your engine and language pair right in the app:

- **OpenAI** — 13 target languages, auto-detecting 70+ source languages.
- **Google Gemini** — ~28 target languages.

## Requirements

- **macOS 26 (Tahoe)** — the interface is built on native Liquid Glass.
- An **API key** for OpenAI or Google Gemini — add both and switch anytime.
- The **BlackHole** virtual audio driver — Unison installs it for you during setup.

## Get started

```bash
git clone https://github.com/NIK-TIGER-BILL/unison.git
cd unison
bash scripts/bundle_app.sh && open build/Unison.app
```

Onboarding installs the audio driver, asks for microphone access, and takes your
API key. Then pick **BlackHole 2ch** as your microphone in the call app and start
translating.

<div align="center">
<sub>Built for macOS 26 Tahoe · Liquid Glass</sub>
</div>
