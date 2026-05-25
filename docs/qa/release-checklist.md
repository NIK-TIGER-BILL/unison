# Unison Release QA Checklist

Run before each release on a fresh macOS 14 VM.

## Installation
- [ ] Download .dmg, mount, drag Unison.app to Applications
- [ ] First launch: onboarding window opens
- [ ] BlackHole 2ch + 16ch install via single password prompt
- [ ] Microphone permission granted
- [ ] API key saved to Keychain

## Call mode (Zoom)
- [ ] Zoom: Mic = BlackHole 2ch, Speaker = BlackHole 16ch
- [ ] Click Start in popover → transcript window appears
- [ ] Speaking RU → peer hears EN
- [ ] Peer speaking EN → I hear RU (loud) + original (quiet)
- [ ] Transcript updates live
- [ ] Click Stop → transcript window closes, sessions terminate

## Listen mode
- [ ] System Settings: Output = BlackHole 16ch
- [ ] Open Spanish-language video on YouTube
- [ ] Start (Listen) → I hear RU translation
- [ ] Stop → restore Output to actual speakers

## Network drops
- [ ] Disable Wi-Fi 5s → reconnect automatic
- [ ] Disable Wi-Fi 30s → toast "Connection lost"

## API errors
- [ ] Invalid API key → toast on Start attempt
- [ ] Insufficient credits → graceful stop with notice

## Settings
- [ ] Change input mic to AirPods → reflected next session
- [ ] Change output device → reflected next session
- [ ] Adjust original volume slider → audible change during active session
