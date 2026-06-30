import Foundation
import UnisonDomain
import UnisonAudio

enum WavIO {
    /// Read a RIFF/WAVE file and return 48 kHz F32 mono samples.
    ///
    /// Scans the chunk list for `fmt ` and `data` (the project's fixtures
    /// carry an `afconvert` `FLLR` filler chunk before `data`, so a
    /// fixed-offset reader does not work). Fixtures are 24 kHz int16 mono;
    /// we wrap the data chunk as an int16 wire-format `AudioFrame` and run it
    /// through the production `ResamplerAdapter` to 48 kHz F32.
    static func read48kMonoF32(path: String) -> [Float] {
        guard let d = FileManager.default.contents(atPath: path), d.count > 12 else { return [] }
        func u32(_ off: Int) -> Int {
            Int(d[off]) | Int(d[off+1]) << 8 | Int(d[off+2]) << 16 | Int(d[off+3]) << 24
        }
        func u16(_ off: Int) -> Int { Int(d[off]) | Int(d[off+1]) << 8 }
        func tag(_ off: Int) -> String { String(bytes: d[off..<off+4], encoding: .ascii) ?? "" }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return [] }

        var rate = 0, channels = 1, bits = 16, isFloat = false
        var dataChunk: Data?
        var i = 12
        while i + 8 <= d.count {
            let id = tag(i)
            let size = u32(i + 4)
            let body = i + 8
            if id == "fmt ", body + 16 <= d.count {
                isFloat = (u16(body) == 3)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
            } else if id == "data" {
                let end = min(body + size, d.count)
                dataChunk = d.subdata(in: body..<end)
            }
            i = body + size + (size & 1)   // chunks are word-aligned
        }
        guard let chunk = dataChunk, rate > 0, channels == 1, bits == 16, !isFloat else {
            FileHandle.standardError.write(Data("aec-eval: expected 24kHz int16 mono WAV at \(path)\n".utf8))
            return []
        }
        let srcFrame = AudioFrame(pcm: chunk, sampleRate: rate, channels: 1, format: .int16)
        let out = ResamplerAdapter().fromWire(srcFrame, targetSampleRate: 48_000)
        return samples(out)
    }

    static func frame(_ s: [Float]) -> AudioFrame {
        var data = Data(count: s.count * 4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in s.indices { p[i] = s[i] }
        }
        return AudioFrame(pcm: data, sampleRate: 48_000, channels: 1, format: .float32)
    }

    static func frameAt(_ s: [Float], rate: Int) -> AudioFrame {
        var data = Data(count: s.count * 4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in s.indices { p[i] = s[i] }
        }
        return AudioFrame(pcm: data, sampleRate: rate, channels: 1, format: .float32)
    }

    static func resample(_ s: [Float], from: Int, to: Int) -> [Float] {
        if from == to { return s }
        return samples(Resampler.resampleToMonoF32(frameAt(s, rate: from), targetSampleRate: to))
    }

    static func samples(_ frame: AudioFrame) -> [Float] {
        guard frame.format == .float32 else { return [] }
        var out = [Float](repeating: 0, count: frame.sampleCount)
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            for i in out.indices { out[i] = p[i] }
        }
        return out
    }
}
