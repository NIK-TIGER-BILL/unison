import Foundation
import UnisonAudio
import UnisonDomain

// aec-eval — offline ERLE harness.
//   swift run aec-eval --near <near.wav> --far <far.wav> [--delay-ms 25]
//                      [--echo-gain 0.5] [--mic-rate 48000]
// Synthesizes mic = near + echo-gain·delay(far) and runs SpeexEchoCanceller
// with `far` as the reference, reporting ERLE per second + overall. Fixtures
// are the project's 24 kHz int16 mono WAVs.
//
// `--mic-rate` models a real device mismatch: the speaker plays `far` at 48 kHz
// but the mic captures at a lower rate (e.g. 16 kHz for a BT-HFP headset). The
// echo is band-limited to the mic rate; the canceller runs at the mic rate.
// This is the live-default path the cross-rate fix exists for — without it the
// harness only exercises the same-rate (48 kHz) case.

func arg(_ name: String, _ def: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return def
}

guard let nearPath = arg("--near"), let farPath = arg("--far") else {
    FileHandle.standardError.write(Data("usage: aec-eval --near <wav> --far <wav> [--delay-ms N] [--echo-gain G] [--mic-rate R]\n".utf8))
    exit(2)
}
let delayMs = Int(arg("--delay-ms", "25")!) ?? 25
let echoGain = Float(arg("--echo-gain", "0.5")!) ?? 0.5
let micRate = Int(arg("--mic-rate", "48000")!) ?? 48_000

let near48 = WavIO.read48kMonoF32(path: nearPath)   // user voice (read as 48 kHz)
let far48 = WavIO.read48kMonoF32(path: farPath)     // speaker output @ 48 kHz
guard !near48.isEmpty, !far48.isEmpty else {
    FileHandle.standardError.write(Data("aec-eval: could not read near/far fixtures\n".utf8))
    exit(1)
}

// The mic captures at `micRate`; the echo it hears is `far` band-limited to the
// mic rate, delayed by the acoustic path. near = the user's voice at mic rate.
let near = WavIO.resample(near48, from: 48_000, to: micRate)
let farAtMic = WavIO.resample(far48, from: 48_000, to: micRate)
let delaySamples = delayMs * micRate / 1000
let n = min(near.count, farAtMic.count)
var mic = [Float](repeating: 0, count: n)
for i in 0..<n {
    let dPos = i - delaySamples
    let echo = dPos >= 0 && dPos < farAtMic.count ? farAtMic[dPos] * echoGain : 0
    mic[i] = near[i] + echo
}

let aec = SpeexEchoCanceller()
let farBlock = 480                     // 10 ms @ 48 kHz (speaker rate)
let micBlock = max(1, micRate / 100)   // 10 ms @ mic rate
var residual = [Float]()
residual.reserveCapacity(mic.count)
let frames = min(far48.count / farBlock, mic.count / micBlock)
for f in 0..<frames {
    aec.pushFarReference(WavIO.frameAt(Array(far48[(f * farBlock)..<((f + 1) * farBlock)]), rate: 48_000))
    let out = WavIO.samples(aec.processNear(WavIO.frameAt(Array(mic[(f * micBlock)..<((f + 1) * micBlock)]), rate: micRate)))
    residual.append(contentsOf: out)
}

let common = min(mic.count, residual.count)
let micPrefix = Array(mic[0..<common])
let res = Array(residual[0..<common])
print("mic-rate=\(micRate) delay=\(delayMs)ms echoGain=\(echoGain)  (near=\(near.count) far@48k=\(far48.count))")
let perSec = micRate
var s = 0
while s + perSec <= res.count {
    let e = EchoMetrics.erleDB(reference: Array(micPrefix[s..<s + perSec]),
                               residual: Array(res[s..<s + perSec]))
    print(String(format: "  t=%2ds  ERLE=%.1f dB", s / perSec, e))
    s += perSec
}
print(String(format: "overall ERLE = %.1f dB", EchoMetrics.erleDB(reference: micPrefix, residual: res)))
