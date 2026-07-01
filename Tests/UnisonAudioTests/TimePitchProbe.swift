import Foundation
import AVFoundation
import Testing

// MARK: - TimePitch offline probe (systematic-debugging Phase 1 evidence)
//
// Hypothesis under test: `AVAudioUnitTimePitch` — the spectral phase-vocoder
// sitting permanently in the translated playback path (translatedPlayer →
// timePitch → mixer) — is NOT transparent at rate=1.0. The v5 pacing
// controller holds rate=1.0 for >90% of ticks, so if the node smears
// transients / adds latency at unity it does so almost all the time, for no
// benefit — a candidate for the user-reported "внезапные деградации звука"
// (sudden audio degradations) and ~90 ms of avoidable latency.
//
// This probe pushes pristine F32/48k signals through the SAME node graph the
// production mixer uses, in AVAudioEngine offline manual-rendering mode (no
// device, deterministic), and measures three configurations:
//   • passthrough      — player → mixer            (baseline: what "clean" is)
//   • timePitchUnity    — player → timePitch(1.0) → mixer  (production today)
//   • timePitchBypass   — player → timePitch(bypass) → mixer  (candidate fix)
//
// It is EVIDENCE-GATHERING, not a behavioural assertion on Apple's framework.
// The `#expect`s are loose sanity guards; the PRINTED metrics are the point.
// Gated behind `UNISON_RUN_PROBES=1` so normal `swift test` stays fast and
// doesn't assert on measured framework timing. Run with:
//   UNISON_RUN_PROBES=1 swift test --filter TimePitchProbe
@Suite(.serialized)
struct TimePitchProbe {
    static let sr = 48_000.0
    static let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sr, channels: 1, interleaved: false)!

    enum Config: String, CaseIterable {
        case passthrough      // player → mixer
        case timePitchUnity   // player → timePitch(rate=1.0) → mixer
        case timePitchBypass  // player → timePitch(bypass=true) → mixer
    }

    static var probesEnabled: Bool {
        ProcessInfo.processInfo.environment["UNISON_RUN_PROBES"] == "1"
    }

    // MARK: - Offline render through the production graph

    /// Render `input` (F32/48k mono) through `config`'s node graph offline and
    /// return the captured post-mixer samples plus the AU's self-reported
    /// processing latency (0 for passthrough). `rate` sets `timePitch.rate`
    /// (ignored for passthrough) so we can probe the burst-drain case (1.03–
    /// 1.06×), not just unity. Deterministic — no hardware.
    static func render(_ input: [Float], config: Config, rate: Double = 1.0) throws -> (out: [Float], reportedLatencySec: Double) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        engine.attach(player)

        switch config {
        case .passthrough:
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
        case .timePitchUnity, .timePitchBypass:
            engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: fmt)
            engine.connect(timePitch, to: engine.mainMixerNode, format: fmt)
            timePitch.rate = Float(rate)
            if config == .timePitchBypass {
                timePitch.auAudioUnit.shouldBypassEffect = true
            }
        }

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: maxFrames)
        try engine.start()
        let reportedLatency = (config == .passthrough) ? 0 : timePitch.auAudioUnit.latency

        let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(input.count))!
        inBuf.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer {
            memcpy(inBuf.floatChannelData![0], $0.baseAddress!, input.count * MemoryLayout<Float>.size)
        }
        player.scheduleBuffer(inBuf, at: nil, options: [], completionHandler: nil)
        player.play()

        // Render the input plus a 0.25 s tail so the phase-vocoder's group
        // delay + any post-input smear are fully captured.
        let total = AVAudioFramePosition(input.count) + AVAudioFramePosition(0.25 * sr)
        var out = [Float](); out.reserveCapacity(Int(total))
        let rb = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames)!
        while engine.manualRenderingSampleTime < total {
            let remaining = total - engine.manualRenderingSampleTime
            let want = AVAudioFrameCount(min(AVAudioFramePosition(maxFrames), remaining))
            let status = try engine.renderOffline(want, to: rb)
            switch status {
            case .success, .insufficientDataFromInputNode:
                let n = Int(rb.frameLength)
                if n > 0 { out.append(contentsOf: UnsafeBufferPointer(start: rb.floatChannelData![0], count: n)) }
                if n == 0 { engine.stop(); return (out, reportedLatency) }  // no progress → stop
            default:
                engine.stop(); return (out, reportedLatency)
            }
        }
        engine.stop()
        return (out, reportedLatency)
    }

    // MARK: - Metrics

    /// Inverse participation ratio of the energy distribution: the effective
    /// number of samples the signal's energy is spread across. A single spike
    /// → ~1; a smeared blob → many. Reported in ms.
    static func energySpreadMs(_ x: [Float]) -> Double {
        var s1 = 0.0, s2 = 0.0
        for v in x { let p = Double(v) * Double(v); s1 += p; s2 += p * p }
        guard s2 > 0 else { return 0 }
        return (s1 * s1 / s2) / sr * 1000.0
    }

    /// (index, value) of peak |sample| — the group delay + height of an
    /// impulse response.
    static func peak(_ x: [Float]) -> (idx: Int, val: Float) {
        var pk: Float = 0, idx = 0
        for (i, v) in x.enumerated() where abs(v) > pk { pk = abs(v); idx = i }
        return (idx, pk)
    }

    /// Peak |sample| in `[from, to)` relative to `peak`, in dB. Measures
    /// pre-echo (energy BEFORE a transient) and post-echo (ringing after) —
    /// the phase-vocoder artifacts that ARE audible because they land in the
    /// quiet region the transient can't mask. Passthrough → ~−∞ (true silence).
    static func echoDB(_ x: [Float], from: Int, to: Int, peak: Float) -> Double {
        var m: Float = 0
        for i in max(0, from)..<min(x.count, to) { m = max(m, abs(x[i])) }
        return 20 * log10(Double(max(m, 1e-12)) / Double(max(peak, 1e-12)))
    }

    /// Best integer alignment lag (0…maxLag) maximizing raw cross-correlation
    /// of `ref` against `sig`.
    static func bestLag(ref: [Float], sig: [Float], maxLag: Int) -> Int {
        var bestLag = 0, best = -Double.greatestFiniteMagnitude
        for lag in 0...maxLag {
            let n = min(ref.count, sig.count - lag)
            if n <= 0 { break }
            var acc = 0.0
            for i in 0..<n { acc += Double(ref[i]) * Double(sig[i + lag]) }
            if acc > best { best = acc; bestLag = lag }
        }
        return bestLag
    }

    /// SNR (dB) of `sig` vs `ref` after optimal delay + gain alignment,
    /// measured over `ref`'s middle 80% (avoids window edges). High → the
    /// path reproduces the signal; low → it smears/distorts it.
    static func alignedSNR(ref: [Float], sig: [Float], maxLag: Int) -> (snrDB: Double, lag: Int) {
        let lag = bestLag(ref: ref, sig: sig, maxLag: maxLag)
        let lo = ref.count / 10, hi = ref.count - ref.count / 10
        var dot = 0.0, sigE = 0.0
        for i in lo..<hi where i + lag < sig.count {
            dot += Double(ref[i]) * Double(sig[i + lag]); sigE += Double(sig[i + lag]) * Double(sig[i + lag])
        }
        let gain = sigE > 0 ? dot / sigE : 1.0   // scale sig → ref (cancels mixer gain)
        var refP = 0.0, errP = 0.0
        for i in lo..<hi where i + lag < sig.count {
            let r = Double(ref[i]), s = Double(sig[i + lag]) * gain
            refP += r * r; errP += (r - s) * (r - s)
        }
        return (10 * log10(refP / max(errP, 1e-12)), lag)
    }

    // MARK: - Signals

    static func impulse(preSilence: Int, tail: Int) -> [Float] {
        var x = [Float](repeating: 0, count: preSilence + 1 + tail)
        x[preSilence] = 1.0
        return x
    }

    /// 1 kHz sine, `durSec` long, with 5 ms raised-cosine ramps on both ends
    /// so the signal itself has no edge clicks to confound the fidelity read.
    static func windowedSine(freq: Double, durSec: Double, amp: Float = 0.5) -> [Float] {
        let n = Int(durSec * sr)
        let ramp = Int(0.005 * sr)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var w: Double = 1
            if i < ramp { w = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(ramp)) }
            else if i >= n - ramp { w = 0.5 - 0.5 * cos(Double.pi * Double(n - i) / Double(ramp)) }
            x[i] = Float(Double(amp) * w * sin(2 * Double.pi * freq * Double(i) / sr))
        }
        return x
    }

    // MARK: - Probes

    static func pad(_ s: String, _ w: Int) -> String {
        s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
    }
    static func f(_ v: Double, _ dp: Int) -> String { String(format: "%.\(dp)f", v) }

    @Test(.enabled(if: TimePitchProbe.probesEnabled))
    func impulseLatencyAndSmear() throws {
        let impAt = 2400
        let input = Self.impulse(preSilence: impAt, tail: 24_000)   // impulse at 50 ms
        print("\n=== TimePitch impulse probe (impulse at sample \(impAt) = 50.0 ms) ===")
        print(Self.pad("config", 18) + Self.pad("peak@ms", 10) + Self.pad("preEcho_dB", 12)
              + Self.pad("postEcho_dB", 12) + "AU_lat_ms")
        for cfg in Self.Config.allCases {
            let (out, lat) = try Self.render(input, config: cfg)
            let (pkIdx, pkVal) = Self.peak(out)
            // Pre-echo: 40 ms window ending 1 ms before the peak (skip the
            // immediate declick ramp). Post-echo: 40 ms after.
            let pre = Self.echoDB(out, from: pkIdx - 1920, to: pkIdx - 48, peak: pkVal)
            let post = Self.echoDB(out, from: pkIdx + 48, to: pkIdx + 1920, peak: pkVal)
            print(Self.pad(cfg.rawValue, 18) + Self.pad(Self.f(Double(pkIdx) / Self.sr * 1000, 2), 10)
                  + Self.pad(Self.f(pre, 1), 12) + Self.pad(Self.f(post, 1), 12) + Self.f(lat * 1000, 2))
            #expect(!out.isEmpty)
        }
        print("(peak@ms = group delay; pre/postEcho_dB = transient smear vs peak, −∞ = clean)\n")
    }

    @Test(.enabled(if: TimePitchProbe.probesEnabled))
    func sineFidelity() throws {
        let input = Self.windowedSine(freq: 1000, durSec: 0.2)
        print("\n=== TimePitch 1 kHz sine fidelity probe (200 ms) ===")
        print(Self.pad("config", 22) + Self.pad("SNR_dB", 12) + "delay_ms")
        // Baselines first.
        for cfg in [Config.passthrough, .timePitchBypass] {
            let (out, _) = try Self.render(input, config: cfg)
            let (snr, lag) = Self.alignedSNR(ref: input, sig: out, maxLag: Int(0.2 * Self.sr))
            print(Self.pad(cfg.rawValue, 22) + Self.pad(Self.f(snr, 1), 12) + Self.f(Double(lag) / Self.sr * 1000, 2))
            #expect(!out.isEmpty)
        }
        // TimePitch across the rates the v5 controller actually uses: unity
        // (>90% of ticks) and the gentle burst-drain band up to maxRate 1.06×.
        for rate in [1.0, 1.03, 1.06] {
            let (out, _) = try Self.render(input, config: .timePitchUnity, rate: rate)
            let (snr, lag) = Self.alignedSNR(ref: input, sig: out, maxLag: Int(0.2 * Self.sr))
            print(Self.pad("timePitch@\(Self.f(rate, 2))×", 22) + Self.pad(Self.f(snr, 1), 12)
                  + Self.f(Double(lag) / Self.sr * 1000, 2))
            #expect(!out.isEmpty)
        }
        print("(SNR_dB after delay+gain align: high = transparent; low = smeared/distorted.\n"
              + " Note @1.03/1.06× the aligned-SNR is dominated by the intended tempo change,\n"
              + " not distortion — read it as 'how far from the original timeline', not quality.)\n")
    }
}
