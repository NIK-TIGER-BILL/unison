import AppKit
import Darwin
import Foundation
import UnisonAudio
import UnisonDomain

public enum SanityCheck {
    public static func run(targetBundleID: String = "us.zoom.xos",
                           durationSeconds: Int = 10) async {
        guard let app = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == targetBundleID }) else {
            print("Sanity check: \(targetBundleID) is not running.")
            print("Start Zoom and join a test call at zoom.us/test, then re-run.")
            return
        }
        let pid = app.processIdentifier
        print("Sanity check: target=\(targetBundleID) pid=\(pid)")

        let capture = ProcessTapCapture(targetPID: pid)
        let toFloats = SanityCheck.framePCMtoFloats(_:)

        // Collect frames inside the Task. All mutation of `collected` is
        // confined to this single Task — no shared mutable state leaks out,
        // so @Sendable is satisfied without an actor.
        let captureTask = Task<[Float], Never> { @Sendable in
            var collected: [Float] = []
            for await frame in capture.start() {
                let floats = toFloats(frame)
                collected.append(contentsOf: floats)
                if Task.isCancelled { break }
            }
            return collected
        }

        try? await Task.sleep(nanoseconds: UInt64(durationSeconds) * 1_000_000_000)
        captureTask.cancel()
        capture.stop()

        let samples = await captureTask.value

        guard !samples.isEmpty else {
            print("Tap returned no samples — process may not be producing audio.")
            return
        }
        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        print("Captured: \(samples.count) frames")
        print("RMS amplitude: \(String(format: "%.4f", rms))")
        if rms > 0.001 {
            print("Verdict: Tap is receiving audio from \(targetBundleID).")
        } else {
            print("Verdict: Tap returned silence — \(targetBundleID) may be muted or no call active.")
        }
    }

    // Static helper so it can be captured as a value before entering the
    // @Sendable Task closure (mirrors BenchmarkRun.framePCMtoFloats pattern).
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
}
