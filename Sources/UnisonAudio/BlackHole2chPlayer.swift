import Foundation
import AVFoundation
import CoreAudio
import os
import UnisonDomain

public final class BlackHole2chPlayer: AudioPlayer, @unchecked Sendable {
    /// `os.Logger` channel for the BlackHole 2ch virtual-mic player. Logs
    /// lifecycle events (engine start / device bind), and any frame format
    /// mismatch that would silently drop audio. Stream:
    ///   log stream --predicate 'subsystem == "com.unison.app" && category == "AudioOutput"' --info
    private static let log = Logger(subsystem: "com.unison.app", category: "AudioOutput")

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let registry: CoreAudioDeviceRegistry
    private var started = false
    /// Latches once per `play(_:)` invocation to keep the format-mismatch
    /// warning out of the per-frame hot path. The first dropped frame
    /// shouts loudly so the diagnostic dump captures it; subsequent
    /// drops are silent until the player restarts.
    private var loggedFormatMismatch = false
    /// Latches once per `play(_:)` invocation when a frame is successfully
    /// scheduled. Used to surface "the pipeline started delivering audio"
    /// exactly once so the log isn't drowned by the per-chunk firehose.
    private var loggedFirstFrame = false

    public init(registry: CoreAudioDeviceRegistry) {
        self.registry = registry
    }

    public func play(_ frames: AsyncStream<AudioFrame>) async {
        Self.log.info("play() entering — about to start engine + iterate frames")
        do {
            try startIfNeeded()
        } catch {
            Self.log.error("play() — startIfNeeded threw: \(String(describing: error), privacy: .public); aborting (no audio will be scheduled)")
            return
        }
        loggedFormatMismatch = false
        loggedFirstFrame = false
        for await frame in frames {
            schedule(frame)
        }
        Self.log.info("play() — frame stream finished")
    }

    public func stop() {
        player.stop()
        engine.stop()
        started = false
    }

    private func startIfNeeded() throws {
        guard !started else { return }
        guard let bh2 = registry.findBlackHole2ch() else {
            Self.log.error("startIfNeeded — BlackHole 2ch device not found in registry")
            throw NSError(domain: "BlackHole2chPlayer", code: -1)
        }
        Self.log.info("startIfNeeded — found BlackHole 2ch device uid=\(bh2.uid, privacy: .public)")

        engine.attach(player)

        // CRITICAL: assign the output device BEFORE wiring graph connections.
        // AVAudioEngine resolves the implicit `mainMixerNode → outputNode`
        // connection against the current output device's hardware sample
        // rate the first time any node connection touches the mixer.
        // Changing the device on the output AudioUnit *after* that point
        // leaves the engine routing to the old (default) device — which
        // is exactly the silent-no-audio-on-BlackHole bug we hit.
        if let deviceID = audioDeviceID(forUID: bh2.uid) {
            var id = deviceID
            let status = AudioUnitSetProperty(
                engine.outputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0,
                &id, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                Self.log.error("startIfNeeded — AudioUnitSetProperty(CurrentDevice → \(bh2.uid, privacy: .public)) failed status=\(status)")
            } else {
                Self.log.info("startIfNeeded — output device bound to BlackHole 2ch (id=\(deviceID))")
            }
        } else {
            Self.log.error("startIfNeeded — audioDeviceID(forUID: \(bh2.uid, privacy: .public)) returned nil; engine will route to default output")
        }

        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        engine.connect(player, to: engine.mainMixerNode, format: format)

        do {
            try engine.start()
        } catch {
            Self.log.error("startIfNeeded — engine.start() threw: \(String(describing: error), privacy: .public)")
            throw error
        }
        player.play()
        started = true
        Self.log.info("startIfNeeded — engine started; player playing; ready to schedule buffers")
    }

    private func schedule(_ frame: AudioFrame) {
        guard frame.format == .float32 else {
            if !loggedFormatMismatch {
                loggedFormatMismatch = true
                Self.log.error("schedule — DROPPING frame: expected .float32, got \(String(describing: frame.format), privacy: .public) at \(frame.sampleRate)Hz × \(frame.channels)ch (\(frame.sampleCount) samples). Subsequent drops silent until next play().")
            }
            return
        }
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(frame.sampleRate),
            channels: AVAudioChannelCount(frame.channels),
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(frame.sampleCount)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buf.frameLength = frameCount
        frame.pcm.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self).baseAddress!
            memcpy(buf.floatChannelData![0], p, frame.pcm.count)
        }
        player.scheduleBuffer(buf, completionHandler: nil)
        if !loggedFirstFrame {
            loggedFirstFrame = true
            Self.log.info("schedule — first frame scheduled to BlackHole 2ch (\(frame.sampleRate)Hz × \(frame.channels)ch, \(frame.sampleCount) samples)")
        }
    }
}
