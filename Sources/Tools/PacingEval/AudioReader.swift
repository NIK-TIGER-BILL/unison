import Foundation
import AVFoundation

/// Reads a WAV/AIFF/M4A file and converts it to 24 kHz int16 mono PCM
/// — the wire format OpenAI's Realtime Translate API expects for
/// `input_audio_buffer.append`. Splits the result into fixed-size chunks
/// matching the real-time wall-clock pace at which the production
/// client streams audio (100 ms per chunk by default).
struct AudioReader {
    let url: URL
    /// Per-chunk size in audio milliseconds. Default 100 ms matches the
    /// production client's mic-capture cadence.
    let chunkMs: Int

    /// 24 kHz int16 mono PCM as one contiguous Data, plus chunk count
    /// for the requested chunkMs.
    struct Decoded {
        let pcm: Data
        let totalSamples: Int
        let sampleRate: Int = 24_000
        let chunkSizeBytes: Int
        var totalDurationSec: Double { Double(totalSamples) / Double(sampleRate) }
        var chunkCount: Int { (pcm.count + chunkSizeBytes - 1) / chunkSizeBytes }
    }

    func decode() throws -> Decoded {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!

        let inputCapacity = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: inputCapacity
        ) else {
            throw PacingEvalError.audioRead("could not allocate input buffer for \(inputCapacity) frames")
        }
        try file.read(into: inputBuffer)

        // Worst-case output frame count: ratio + a few frames slack.
        let outputCapacity = AVAudioFrameCount(
            Double(inputBuffer.frameLength) * 24_000.0 / inputFormat.sampleRate
        ) + 256
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputCapacity
        ) else {
            throw PacingEvalError.audioRead("could not allocate output buffer for \(outputCapacity) frames")
        }

        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)!
        // The converter callback runs on an internal queue and is typed
        // @Sendable. Wrap input + "consumed?" flag in a small actor-ish
        // class so the closure body itself doesn't capture mutable
        // outer state (which Swift 6 strict concurrency rejects).
        let state = ConvertInputState(buffer: inputBuffer)
        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { _, statusPtr in
            if let b = state.takeOnce() {
                statusPtr.pointee = .haveData
                return b
            }
            statusPtr.pointee = .endOfStream
            return nil
        }
        if let error {
            throw PacingEvalError.audioRead("converter failed: \(error.localizedDescription)")
        }

        let frames = Int(outputBuffer.frameLength)
        let bytes = frames * 2  // int16 mono
        var pcm = Data(count: bytes)
        pcm.withUnsafeMutableBytes { dst in
            let src = outputBuffer.int16ChannelData![0]
            memcpy(dst.baseAddress!, src, bytes)
        }

        // chunkMs → samples → bytes
        let samplesPerChunk = (chunkMs * 24_000) / 1_000
        let bytesPerChunk = samplesPerChunk * 2
        return Decoded(
            pcm: pcm,
            totalSamples: frames,
            chunkSizeBytes: bytesPerChunk
        )
    }
}

/// Slice `Decoded.pcm` into iterable chunks of exactly `chunkSizeBytes`
/// each (last chunk may be shorter, zero-padded for consistent timing).
struct AudioChunkIterator: Sequence {
    let decoded: AudioReader.Decoded

    func makeIterator() -> AnyIterator<Data> {
        var offset = 0
        let pcm = decoded.pcm
        let chunkSize = decoded.chunkSizeBytes
        return AnyIterator {
            guard offset < pcm.count else { return nil }
            // Swift.min() — local `min` from Sequence shadows the
            // free function when accessed via a property like
            // `self.decoded.pcm.min` resolved at this scope.
            let end = Swift.min(offset + chunkSize, pcm.count)
            var slice = pcm.subdata(in: offset..<end)
            if slice.count < chunkSize {
                slice.append(Data(count: chunkSize - slice.count))
            }
            offset = end
            return slice
        }
    }
}

/// Wraps the AVAudioPCMBuffer that the converter callback returns
/// exactly once, then signals end-of-stream. Class-with-lock pattern
/// (mirrors `ConverterInputState` in Resampler.swift) so the
/// @Sendable closure body itself does no mutation.
private final class ConvertInputState: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    private let lock = NSLock()
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func takeOnce() -> AVAudioPCMBuffer? {
        lock.lock(); defer { lock.unlock() }
        let b = buffer
        buffer = nil
        return b
    }
}

enum PacingEvalError: Error, CustomStringConvertible {
    case audioRead(String)
    case missingApiKey
    case sessionFailure(String)

    var description: String {
        switch self {
        case .audioRead(let s): return "audio read failed: \(s)"
        case .missingApiKey: return "OPENAI_API_KEY env var not set"
        case .sessionFailure(let s): return "session failure: \(s)"
        }
    }
}
