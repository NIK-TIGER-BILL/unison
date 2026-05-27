import AVFoundation
import CoreAudio
import Foundation
import UnisonAudio
import UnisonDomain

public enum BenchmarkPhase: String, Sendable {
    case blackhole
    case tap
}

public struct PhaseConfig {
    public let phase: BenchmarkPhase
    public let durationSeconds: Int
    public let clickCount: Int
    public let outputDeviceID: AudioDeviceID
    public let silentMode: Bool

    public init(phase: BenchmarkPhase, durationSeconds: Int,
                outputDeviceID: AudioDeviceID, silentMode: Bool) {
        self.phase = phase
        self.durationSeconds = durationSeconds
        self.clickCount = durationSeconds * 5  // 200ms intervals → 5 clicks/sec
        self.outputDeviceID = outputDeviceID
        self.silentMode = silentMode
    }
}

public final class BenchmarkRun {
    public let config: PhaseConfig

    public init(config: PhaseConfig) {
        self.config = config
    }

    public func run() async throws -> PhaseMetrics {
        let signal = try SignalGenerator()
        try signal.setOutputDevice(config.outputDeviceID)
        signal.setGain(dB: config.silentMode ? -120 : -40)

        let cpu = CPUSampler()
        cpu.start()
        defer { cpu.stop() }

        let captureTask: Task<[(UInt64, [Float], Int)], Error>
        switch config.phase {
        case .blackhole:
            captureTask = startCaptureBlackHole()
        case .tap:
            captureTask = startCaptureTap()
        }

        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms settle
        try signal.startAndScheduleClicks(clickCount: config.clickCount)
        try await signal.waitUntilFinished()
        signal.stop()

        try await Task.sleep(nanoseconds: 500_000_000)  // 500ms tail
        captureTask.cancel()

        let captured = (try? await captureTask.value) ?? []
        return analyse(captured: captured,
                       expected: signal.expectedClickHostTimes,
                       cpuSamples: cpu.samples)
    }

    private func startCaptureBlackHole() -> Task<[(UInt64, [Float], Int)], Error> {
        let toFloats = BenchmarkRun.framePCMtoFloats(_:)
        return Task { @Sendable in
            let registry = CoreAudioDeviceRegistry()
            let capture = BlackHoleSinkCapture(registry: registry)
            var chunks: [(UInt64, [Float], Int)] = []
            for await frame in capture.start() {
                let host = HostTimeClock.now()
                let floats = toFloats(frame)
                chunks.append((host, floats, frame.sampleRate))
                if Task.isCancelled { break }
            }
            capture.stop()
            return chunks
        }
    }

    private func startCaptureTap() -> Task<[(UInt64, [Float], Int)], Error> {
        let toFloats = BenchmarkRun.framePCMtoFloats(_:)
        return Task { @Sendable in
            let capture = ProcessTapCapture(targetPID: getpid())
            var chunks: [(UInt64, [Float], Int)] = []
            for await frame in capture.start() {
                let host = HostTimeClock.now()
                let floats = toFloats(frame)
                chunks.append((host, floats, frame.sampleRate))
                if Task.isCancelled { break }
            }
            capture.stop()
            return chunks
        }
    }

    private static func framePCMtoFloats(_ frame: AudioFrame) -> [Float] {
        let count = frame.pcm.count / MemoryLayout<Float>.size
        var floats = [Float](repeating: 0, count: count)
        floats.withUnsafeMutableBytes { dst in
            frame.pcm.withUnsafeBytes { src in
                if let dstBase = dst.baseAddress, let srcBase = src.baseAddress {
                    memcpy(dstBase, srcBase, frame.pcm.count)
                }
            }
        }
        return floats
    }

    private func analyse(
        captured: [(UInt64, [Float], Int)],
        expected: [UInt64],
        cpuSamples: [Double]
    ) -> PhaseMetrics {
        // Refractory is ~100ms; sample-rate-aware so the window stays 100ms
        // regardless of whether the capture is 44.1, 48, or 96 kHz.
        let firstRate = captured.first?.2 ?? 48000
        let detector = PeakDetector(
            threshold: 0.3,
            refractorySamples: max(1, firstRate / 10)
        )
        var detectedTimes: [UInt64] = []

        for (chunkHostTime, samples, sampleRate) in captured {
            let peaks = detector.detectPeaks(in: samples)
            let nsPerSample: Double = 1_000_000_000 / Double(sampleRate)
            for peakIdx in peaks {
                let offsetNs = UInt64(Double(peakIdx) * nsPerSample)
                let offsetTicks = offsetNs * UInt64(HostTimeClock.timebase.denom) /
                                  UInt64(HostTimeClock.timebase.numer)
                detectedTimes.append(chunkHostTime + offsetTicks)
            }
        }

        return MetricsCalculator.compute(
            expectedClickTimes: expected,
            detectedClickTimes: detectedTimes,
            matchWindowMs: 100,
            cpuSamples: cpuSamples
        )
    }
}
