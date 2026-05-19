import Foundation
import UnisonDomain

public final class AudioBatcher: @unchecked Sendable {
    public let chunkByteSize: Int
    public let sampleRate: Int
    public let channels: Int
    public let format: AudioSampleFormat

    private var buffer = Data()
    private let lock = NSLock()
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    public let output: AsyncStream<AudioFrame>

    public init(targetChunkMs: Int, sampleRate: Int, channels: Int, format: AudioSampleFormat) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        let bytesPerSample = format == .int16 ? 2 : 4
        let samplesPerChunk = sampleRate * targetChunkMs / 1000
        self.chunkByteSize = samplesPerChunk * channels * bytesPerSample

        var c: AsyncStream<AudioFrame>.Continuation!
        self.output = AsyncStream { c = $0 }
        self.continuation = c
    }

    public func feed(_ frame: AudioFrame) {
        lock.lock()
        buffer.append(frame.pcm)
        while buffer.count >= chunkByteSize {
            let chunk = buffer.prefix(chunkByteSize)
            buffer.removeFirst(chunkByteSize)
            let f = AudioFrame(pcm: Data(chunk), sampleRate: sampleRate, channels: channels, format: format)
            lock.unlock()
            continuation?.yield(f)
            lock.lock()
        }
        lock.unlock()
    }

    public func finish() {
        continuation?.finish()
    }
}
