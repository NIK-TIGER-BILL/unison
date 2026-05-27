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

    /// Swap the system default output to `device`, returning the previous device
    /// so the caller can restore it. Returns nil if either get or set fails.
    private func swapDefaultOutput(to device: AudioDeviceID) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var prev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       0, nil, &size, &prev) != noErr {
            return nil
        }
        var newID = device
        if AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       0, nil, UInt32(MemoryLayout<AudioDeviceID>.size),
                                       &newID) != noErr {
            return nil
        }
        return prev
    }

    public func run() async throws -> PhaseMetrics {
        // For the BlackHole phase, make the capture device the system default
        // output during the phase. BlackHole 16ch is a virtual device — its
        // device clock only runs when an app is actively playing to it; by
        // pinning it as the default output the HAL keeps ticking and our
        // AUHAL render callback fires continuously rather than once.
        let savedDefault: AudioDeviceID? = config.phase == .blackhole
            ? swapDefaultOutput(to: config.outputDeviceID)
            : nil
        defer {
            if let saved = savedDefault { _ = swapDefaultOutput(to: saved) }
        }

        let signal = AUHALSignalGenerator()
        try signal.setOutputDevice(config.outputDeviceID)
        signal.setGain(dB: 0)

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
        let deviceID = config.outputDeviceID
        return Task { @Sendable in
            let capture = AUHALInputCapture()
            try capture.start(deviceID: deviceID)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            capture.stop()
            return capture.snapshot().map { ($0.hostTime, $0.samples, $0.sampleRate) }
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
        // Threshold is well below the 0.7 click amplitude. The device-side
        // round-trip can attenuate (BH 16ch's mono→multichannel routing),
        // so we accept anything above ambient noise.
        let detector = PeakDetector(
            threshold: 0.05,
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
