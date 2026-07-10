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

<br><br>

<a href="https://github.com/NIK-TIGER-BILL/unison/blob/main/docs/videos/demo.mp4"><img src="docs/videos/demo-poster.jpg" alt="Watch the 30-second Unison demo" width="300"></a>

<br>
<sub>▶ 30-second demo — plays with sound</sub>

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

<div align="center">
  <img src="docs/images/menu.png" alt="Unison menu-bar popover" width="380"><br>
  <sub>Pick your direction (<b>Call</b> or <b>Listen</b>) and the language pair, then
  start in one click.</sub>
</div>

## Languages

Choose your engine and language pair right in the app:

- **OpenAI** — 13 target languages, auto-detecting 70+ source languages.
- **Google Gemini** — ~28 target languages.

## Requirements

- **macOS 26 (Tahoe)** — the interface is built on native Liquid Glass.
- An **API key** for OpenAI or Google Gemini — add both and switch anytime.
- The **BlackHole** virtual audio driver — Unison installs it for you during setup.

## Install

1. Download **Unison.dmg** from the
   [latest release](https://github.com/NIK-TIGER-BILL/unison/releases/latest)
   and drag **Unison** into **Applications**.
2. Open Unison. macOS will refuse the first launch — the app isn't notarized
   (no paid Apple Developer subscription behind this project). Click **Done**
   — *not* "Move to Trash".
3. Go to **System Settings → Privacy & Security**, scroll down to
   *"Unison" was blocked to protect your Mac*, click **Open Anyway** and
   confirm. One time only — after this it opens like any other app.

Onboarding does the rest: installs the audio driver, asks for microphone
access, takes your API key. Then pick **BlackHole 2ch** as your microphone in
the call app and start translating.

<details>
<summary>Build from source instead</summary>
<br>

```bash
git clone https://github.com/NIK-TIGER-BILL/unison.git
cd unison
bash scripts/bundle_app.sh && open build/Unison.app
```

A locally built app is signed on your machine, so Gatekeeper lets it straight through.

</details>

<div align="center">
<sub>Built for macOS 26 Tahoe · Liquid Glass</sub>
</div>
