import Foundation
import UnisonAudio
import UnisonDomain

// aec-eval — offline ERLE harness.
//   swift run aec-eval --near <near.wav> --far <far.wav> [--delay-ms 25] [--echo-gain 0.5]
// Synthesizes mic = near + echo-gain·delay(far), runs SpeexEchoCanceller with
// `far` as the reference, reports ERLE per second + overall. Fixtures are the
// project's 24 kHz int16 mono WAVs (resampled to 48 kHz internally).

func arg(_ name: String, _ def: String? = nil) -> String? {
    let a = CommandLine.arguments
    if let i = a.firstIndex(of: name), i + 1 < a.count { return a[i + 1] }
    return def
}

guard let nearPath = arg("--near"), let farPath = arg("--far") else {
    FileHandle.standardError.write(Data("usage: aec-eval --near <wav> --far <wav> [--delay-ms N] [--echo-gain G]\n".utf8))
    exit(2)
}
let delayMs = Int(arg("--delay-ms", "25")!) ?? 25
let echoGain = Float(arg("--echo-gain", "0.5")!) ?? 0.5

let near = WavIO.read48kMonoF32(path: nearPath)
let far = WavIO.read48kMonoF32(path: farPath)
guard !near.isEmpty, !far.isEmpty else {
    FileHandle.standardError.write(Data("aec-eval: could not read near/far fixtures\n".utf8))
    exit(1)
}
let delaySamples = delayMs * 48
let n = min(near.count, far.count)

var mic = [Float](repeating: 0, count: n)
for i in 0..<n {
    let dPos = i - delaySamples
    let echo = dPos >= 0 && dPos < far.count ? far[dPos] * echoGain : 0
    mic[i] = near[i] + echo
}

let aec = SpeexEchoCanceller()
let block = 480
var residual = [Float]()
residual.reserveCapacity(n)
var i = 0
while i + block <= n {
    aec.pushFarReference(WavIO.frame(Array(far[i..<i+block])))
    let out = WavIO.samples(aec.processNear(WavIO.frame(Array(mic[i..<i+block]))))
    residual.append(contentsOf: out)
    i += block
}

let micPrefix = Array(mic[0..<residual.count])
print("delay=\(delayMs)ms echoGain=\(echoGain)  (samples: near=\(near.count) far=\(far.count))")
let perSec = 48_000
var s = 0
while s + perSec <= residual.count {
    let e = EchoMetrics.erleDB(reference: Array(micPrefix[s..<s+perSec]),
                               residual: Array(residual[s..<s+perSec]))
    print(String(format: "  t=%2ds  ERLE=%.1f dB", s / perSec, e))
    s += perSec
}
let overall = EchoMetrics.erleDB(reference: micPrefix, residual: residual)
print(String(format: "overall ERLE = %.1f dB", overall))
