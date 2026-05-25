import Foundation

public enum AudioSampleFormat: Sendable {
    case float32
    case int16
}

public struct AudioFrame: Sendable, Equatable {
    public let pcm: Data
    public let sampleRate: Int
    public let channels: Int
    public let format: AudioSampleFormat

    public init(pcm: Data, sampleRate: Int, channels: Int, format: AudioSampleFormat) {
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
    }

    public var bytesPerSample: Int {
        switch format {
        case .float32: 4
        case .int16: 2
        }
    }

    public var sampleCount: Int {
        pcm.count / (bytesPerSample * channels)
    }

    public var durationMs: Double {
        Double(sampleCount) * 1000.0 / Double(sampleRate)
    }
}
