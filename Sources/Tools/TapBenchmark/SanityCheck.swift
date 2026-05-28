import AppKit
import Darwin
import Foundation
import UnisonAudio
import UnisonDomain

public enum SanityCheck {
    public static func run(targetBundleID: String = "us.zoom.xos",
                           overridePID: pid_t? = nil,
                           durationSeconds: Int = 10) async {
        // FIXME(process-tap-integration): sanity-check needs reworking — the old
        // targetPID API was perfect for "tap this one process". The new
        // excludedBundleIDs API doesn't fit. Defer to a follow-up task.
        print("Sanity check temporarily disabled — see FIXME in SanityCheck.swift")
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
