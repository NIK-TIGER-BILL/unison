import Foundation
import AVFoundation
import UnisonDomain

/// `MicrophoneCapture` implementation that reads frames from a WAV file
/// on disk instead of a real input device.
///
/// **Why this exists.** Real microphone capture (`AVAudioEngine`) does
/// not function inside the Tart VM we use for integration testing —
/// there is no input device and Core Audio happily returns empty buffers.
/// That blocks any automated end-to-end check of the
/// `mic → resampler → OpenAI → mixer → BlackHole` pipeline. This shim
/// lets the test harness inject a pre-recorded utterance (e.g. five
/// seconds of Russian speech) and observe the rest of the pipeline
/// behave exactly as it would on hardware.
///
/// **Activation.** Wired into `Composition.swift` behind the
/// `UNISON_TEST_AUDIO` env var. Production launches never set the var,
/// so the production path keeps using `AVAudioEngineMicrophone`.
///
/// **Frame shape contract.** Emits `AudioFrame(sampleRate: 24_000,
/// channels: 1, format: .int16)` so the downstream `Resampler.toWire`
/// is a no-op — keeping the test path semantically identical to "the
/// mic already produced wire-format frames". The chunking matches the
/// real engine's `bufferSize: 2400` tap (≈100 ms at 24 kHz) so per-frame
/// timing assumptions in the orchestrator and the OpenAI batcher hold
/// without modification.
///
/// **Looping.** The file plays end-to-end then loops back to the start
/// for as long as `start()` is observed. This lets a 5 s fixture cover
/// an arbitrarily long test window without staging multiple files.
public final class FileMicrophoneCapture: MicrophoneCapture, @unchecked Sendable {
    /// Diagnostic logger so a missing/corrupt fixture surfaces in the
    /// same persisted log file as everything else (instead of dying
    /// silently inside `AVAudioFile`).
    private static let log = UnisonLog(category: "FileMicrophone")

    public let fileURL: URL
    /// Chunk size emitted per frame — frames of this size, at 24 kHz
    /// int16 mono, equal ~100 ms which mirrors the AVAudioEngine tap
    /// and gives the OpenAI batcher a steady cadence. Sized so a 24 kHz
    /// frame works out to exactly 2400 samples × 2 bytes = 4800 bytes.
    public static let samplesPerFrame: Int = 2_400
    /// Wall-clock delay between emitted frames. We could fire them all
    /// at once, but pacing matches a real microphone so the OpenAI
    /// batcher and the orchestrator don't see an unrealistic "5 seconds
    /// of audio in 5 ms" burst that hides timing bugs.
    public static let interFrameDelaySeconds: Double = 0.1

    /// Optional override for whether to loop the file. Set to `false`
    /// for unit tests that want a single-pass; the default `true`
    /// matches the integration-test "play forever until stopped" need.
    public var loop: Bool = true

    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    public init(fileURL: URL, loop: Bool = true) {
        self.fileURL = fileURL
        self.loop = loop
    }

    public func start(deviceUID: String?) -> AsyncStream<AudioFrame> {
        Self.log.info("start(deviceUID=\(deviceUID ?? "<nil>")) — reading from \(fileURL.path)")
        // Mirror the real-mic idempotency guard: orchestrator's reconnect
        // path calls `wireOutgoingPipeline → micCapture.start()` without
        // a paired stop, so a second start without reset would leave
        // *two* `runLoop` tasks emitting frames in parallel — both
        // pumping into the same continuation, doubling the apparent
        // mic rate and confusing the OpenAI batcher. Reset on re-entry.
        if task != nil {
            stop()
        }
        return AsyncStream<AudioFrame> { [weak self] cont in
            guard let self else { cont.finish(); return }
            self.continuation = cont
            self.task = Task { [weak self] in
                await self?.runLoop(continuation: cont)
            }
            cont.onTermination = { [weak self] _ in
                self?.task?.cancel()
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
    }

    /// Decode the WAV once into an `int16 @ 24 kHz mono` buffer and
    /// loop-emit `samplesPerFrame`-sized slices. Doing the format
    /// conversion up front keeps the per-tick path free of `AVAudioFile`
    /// state mutation, which simplifies the cancellation handling.
    private func runLoop(continuation: AsyncStream<AudioFrame>.Continuation) async {
        let pcm: Data
        do {
            pcm = try Self.loadAsInt16Mono24k(url: fileURL)
        } catch {
            Self.log.error("failed to load test audio \(fileURL.path): \(String(describing: error))")
            continuation.finish()
            return
        }
        let bytesPerSample = 2 // int16 mono
        let bytesPerFrame = Self.samplesPerFrame * bytesPerSample
        Self.log.info("loaded \(pcm.count) bytes (\(pcm.count / bytesPerSample) samples ≈ \(Double(pcm.count) / Double(bytesPerSample) / 24_000.0)s) — emitting \(bytesPerFrame)-byte chunks every \(Int(Self.interFrameDelaySeconds * 1000))ms")

        var offset = 0
        while !Task.isCancelled {
            if offset >= pcm.count {
                if loop {
                    offset = 0
                } else {
                    continuation.finish()
                    return
                }
            }
            let end = min(offset + bytesPerFrame, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            offset = end
            let frame = AudioFrame(
                pcm: chunk,
                sampleRate: 24_000,
                channels: 1,
                format: .int16
            )
            continuation.yield(frame)
            try? await Task.sleep(nanoseconds: UInt64(Self.interFrameDelaySeconds * 1_000_000_000))
        }
        continuation.finish()
    }

    /// Read a WAV file, downmix to mono and resample to 24 kHz int16.
    /// Uses `AVAudioFile` + `AVAudioConverter` so we don't have to
    /// hand-roll a WAV parser; AVFoundation handles every variant we'd
    /// see in practice (16-bit, 24-bit, 32-bit float, 44.1k, 48k, etc.).
    ///
    /// Exposed `internal` so the unit test can drive the same code path
    /// without going through the `start()`/`AsyncStream` plumbing.
    internal static func loadAsInt16Mono24k(url: URL) throws -> Data {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "FileMicrophoneCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate input PCM buffer"])
        }
        try file.read(into: inBuf)

        // Target: int16, 24 kHz, mono — exactly the OpenAI wire format
        // so `Resampler.toWire` is a no-op on these frames.
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "FileMicrophoneCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to construct output format"])
        }
        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "FileMicrophoneCapture", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to construct converter"])
        }

        // Estimate output frame capacity from the input frame count
        // scaled by sample-rate ratio plus a small slack for rounding.
        let ratio = 24_000.0 / inFormat.sampleRate
        let outFrameCap = AVAudioFrameCount(Double(frameCount) * ratio + 1024)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outFrameCap) else {
            throw NSError(domain: "FileMicrophoneCapture", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to allocate output PCM buffer"])
        }
        // Single-shot input: pass the entire buffer once, then end-of-stream.
        let inputProvided = NSLock()
        nonisolated(unsafe) var providedOnce = false
        var error: NSError?
        let status = converter.convert(to: outBuf, error: &error) { _, statusPtr in
            inputProvided.lock(); defer { inputProvided.unlock() }
            if !providedOnce {
                providedOnce = true
                statusPtr.pointee = .haveData
                return inBuf
            }
            statusPtr.pointee = .endOfStream
            return nil
        }
        if status == .error, let e = error { throw e }

        let frames = Int(outBuf.frameLength)
        let bytes = frames * 2 // int16 mono
        guard let int16Ptr = outBuf.int16ChannelData?[0] else {
            throw NSError(domain: "FileMicrophoneCapture", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Output buffer missing int16 channel data"])
        }
        return Data(bytes: int16Ptr, count: bytes)
    }
}
