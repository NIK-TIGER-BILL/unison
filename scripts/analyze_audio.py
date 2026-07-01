#!/usr/bin/env python3
"""Objective audio-artifact scanner for autonomous playback testing.

Scans a mono WAV (int16 OR IEEE-float32 — including the float dumps written by
`UNISON_DUMP_PLAYBACK_WAV` / `UNISON_DUMP_OUTPUT_WAV`, which Python's stdlib
`wave` can't read) for the artifacts that sound like the user-reported problems,
so we can verify audio quality WITHOUT a human listening:

  • sample-step glitches   — hard sample-to-sample discontinuities = CLICKS
  • sudden RMS jumps       — >=9 dB / 20 ms between voiced frames = pumping/degrade
  • mid-speech dropouts    — silent runs flanked by voiced audio (gaps)
  • clipping               — samples pinned at full scale
  • fade                   — last-second vs first-second RMS envelope

Calibrate against a clean reference (natural speech, or the raw model output):
dropouts + RMS jumps fire on natural speech too, so compare rates, don't read a
raw count as a defect. Glitches + clipping should be ~0 in clean audio.

Usage:
  scripts/analyze_audio.py <path.wav> [label]

Requires numpy. Pairs with `pacing-eval --full-chain-render` (drives real
model output through the production AVAudioOutputMixer and dumps the result).
"""
import sys, struct, numpy as np


def load(path):
    """Manual WAV parse — PCM int16 AND IEEE float32 (fmt tag 3), plus the
    0xFFFFFFFF data-size sentinel our dump writer leaves if killed before stop."""
    with open(path, "rb") as f:
        buf = f.read()
    assert buf[:4] == b"RIFF" and buf[8:12] == b"WAVE", "not a WAV file"
    fmt_tag = ch = bits = sr = data = None
    pos = 12
    while pos + 8 <= len(buf):
        cid = buf[pos:pos + 4]
        csz = struct.unpack_from("<I", buf, pos + 4)[0]
        body = pos + 8
        if cid == b"fmt ":
            fmt_tag, ch, sr, _, _, bits = struct.unpack_from("<HHIIHH", buf, body)
        elif cid == b"data":
            if csz == 0xFFFFFFFF or body + csz > len(buf):
                csz = len(buf) - body
            data = buf[body:body + csz]
            break
        pos = body + csz + (csz & 1)
    if data is None or fmt_tag is None:
        raise SystemExit("no fmt/data chunk")
    if fmt_tag == 3 and bits == 32:
        x = np.frombuffer(data, dtype="<f4").astype(np.float64)
    elif fmt_tag == 1 and bits == 16:
        x = np.frombuffer(data, dtype="<i2").astype(np.float64) / 32768.0
    else:
        raise SystemExit(f"unsupported WAV: fmt tag={fmt_tag} bits={bits}")
    if ch and ch > 1:
        x = x[: len(x) // ch * ch].reshape(-1, ch).mean(axis=1)
    return x, sr


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    path = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else path.rsplit("/", 1)[-1]
    x, sr = load(path)
    print(f"\n===== {label} =====")
    print(f"sr={sr}Hz  dur={len(x) / sr:.2f}s  samples={len(x)}")
    if len(x) == 0:
        return
    peak = float(np.max(np.abs(x)))
    print(f"peak={peak:.4f}  clipping(|x|>=0.99)={np.mean(np.abs(x) >= 0.99) * 100:.3f}%")

    fl = int(0.02 * sr)                          # 20 ms frames
    nf = len(x) // fl
    rms = np.sqrt((x[: nf * fl].reshape(nf, fl) ** 2).mean(axis=1) + 1e-12)
    floor = max(0.004, np.percentile(rms, 25) * 0.5)
    voiced = rms > floor

    runs, i = [], 0
    while i < nf:
        if not voiced[i]:
            j = i
            while j < nf and not voiced[j]:
                j += 1
            if i > 0 and j < nf and voiced[i - 1] and voiced[j]:
                runs.append((i * fl / sr, (j - i) * fl / sr))
            i = j
        else:
            i += 1
    midgaps = [(t, d) for (t, d) in runs if d >= 0.06]
    print(f"mid-speech dropouts >=60ms: {len(midgaps)}  total={sum(d for _, d in midgaps):.2f}s")
    for t, d in midgaps[:8]:
        print(f"    dropout @ {t:6.2f}s  {d * 1000:5.0f}ms")

    db = 20 * np.log10(rms + 1e-9)
    jumps = [(k * fl / sr, db[k] - db[k - 1]) for k in range(1, nf)
             if voiced[k] and voiced[k - 1] and abs(db[k] - db[k - 1]) >= 9]
    print(f"sudden voiced-RMS jumps >=9dB/20ms: {len(jumps)}")
    for t, d in jumps[:8]:
        print(f"    jump @ {t:6.2f}s  {d:+5.1f}dB")

    dx = np.abs(np.diff(x))
    thr = max(0.12, np.percentile(dx, 99.99) * 4)
    g = np.where(dx > thr)[0]
    print(f"sample-step glitches (|dx|>{thr:.3f}): {len(g)}   "
          f"[max|dx|={dx.max():.4f}  #>0.2={int((dx > 0.2).sum())}]")
    for idx in g[:8]:
        print(f"    glitch @ {idx / sr:6.2f}s  step={dx[idx]:.3f}")

    sl = int(sr)
    ns = len(x) // sl
    if ns >= 2:
        seg = [np.sqrt((x[s * sl:(s + 1) * sl] ** 2).mean()) for s in range(ns)]
        print(f"envelope: first={seg[0]:.4f} last={seg[-1]:.4f} "
              f"ratio={seg[-1] / (seg[0] + 1e-9):.2f} (1.0=stable, <0.8=fade)")


if __name__ == "__main__":
    main()
