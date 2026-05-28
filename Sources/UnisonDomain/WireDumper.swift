import Foundation

/// Diagnostic process-wide WAV writer for raw model output (the
/// `session.output_audio.delta` bytes coming back from OpenAI's
/// Realtime Translate API before any of our resampling / scheduling /
/// playback nodes touch them). Enabled by the env var
/// `UNISON_DUMP_WIRE_WAV=<path>` — silent no-op otherwise.
///
/// Pairs with `UNISON_DUMP_PLAYBACK_WAV` (the timePitch-output tap in
/// AVAudioOutputMixer) so we can record BOTH the model's raw output
/// AND what the speakers eventually receive, then compare them by
/// ear to localise quality-degradation artefacts.
///
/// Format: 24 kHz int16 mono PCM, matching the wire format OpenAI's
/// Realtime API emits. WAV header is written once on the first call;
/// the `data` chunk size is left as the 0xFFFF_FFFF sentinel because
/// we don't know when the session will end — most WAV players read
/// to EOF when they see that value.
public final class WireDumper: @unchecked Sendable {
    /// Bytes RECEIVED from OpenAI Realtime Translate (model's translation
    /// output). Env: `UNISON_DUMP_WIRE_WAV`.
    public static let shared = WireDumper(
        category: "WireDumper",
        envVar: "UNISON_DUMP_WIRE_WAV"
    )
    /// Bytes SENT to OpenAI Realtime Translate (what the model receives
    /// as input — i.e. our wire-format encoding of source audio after
    /// the Resampler downsamples to 24 kHz int16). Compare to `.shared`
    /// (output) to localise whether amplitude fade is introduced by
    /// the model or already present in our input.
    /// Env: `UNISON_DUMP_SENT_WAV`.
    public static let sent = WireDumper(
        category: "SentDumper",
        envVar: "UNISON_DUMP_SENT_WAV"
    )

    private let category: String
    private let envVar: String
    private let log: UnisonLog

    private let lock = NSLock()
    private var handle: FileHandle?
    private var initialised = false
    private var firstCallSeen = false
    private var writeCount: Int = 0
    private var bytesWritten: UInt64 = 0

    private init(category: String, envVar: String) {
        self.category = category
        self.envVar = envVar
        self.log = UnisonLog(category: category)
    }

    /// Append one delta's worth of int16 PCM to the dump file. Cheap
    /// — opens the file on the first call, then just appends. Caller
    /// is the orchestrator's pipeline pump.
    public func write(_ pcm: Data) {
        lock.lock(); defer { lock.unlock() }
        let envPath = ProcessInfo.processInfo.environment[envVar]
        // Log the first call's view of the env var so we can verify
        // whether the env var propagated into the process.
        if !firstCallSeen {
            firstCallSeen = true
            if let envPath, !envPath.isEmpty {
                log.info("\(category) first call — env path=\(envPath)")
            } else {
                log.info("\(category) first call — \(envVar) NOT SET; dumping disabled.")
            }
        }
        guard let path = envPath, !path.isEmpty else { return }
        if !initialised {
            initialised = true
            let url = URL(fileURLWithPath: path)
            FileManager.default.createFile(atPath: path, contents: nil)
            guard let h = try? FileHandle(forWritingTo: url) else {
                log.error("\(category) — failed to open \(path) for writing")
                return
            }
            h.write(Self.buildWAVHeader(sampleRate: 24_000,
                                        channels: 1,
                                        bitsPerSample: 16,
                                        dataSize: 0xFFFF_FFFF))
            handle = h
            log.info("\(category) — opened \(path) for raw 24kHz int16 PCM capture")
        }
        handle?.write(pcm)
        writeCount += 1
        bytesWritten &+= UInt64(pcm.count)
        // Periodic heartbeat — debug-level so the per-session user log
        // isn't flooded. Lifecycle events (first call, open, close)
        // stay at info because they're one-shot signals.
        if writeCount % 50 == 0 {
            log.debug("\(category) — \(writeCount) frames dumped (\(bytesWritten) bytes)")
        }
    }

    /// Close the dump file. Patches the WAV `data` chunk size from the
    /// `0xFFFF_FFFF` sentinel to the actual byte count so `ffprobe` and
    /// strict players read the file correctly. Call from the
    /// orchestrator's `stop()` so a session boundary finalises the
    /// header. Safe to call when not initialised — silent no-op.
    public func close() {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return }
        let dataSize = UInt32(truncatingIfNeeded: bytesWritten)
        let fileSize = dataSize &+ 36
        try? handle.seek(toOffset: 4)
        handle.write(Self.uint32LE(fileSize))
        try? handle.seek(toOffset: 40)
        handle.write(Self.uint32LE(dataSize))
        try? handle.close()
        self.handle = nil
        initialised = false
        writeCount = 0
        bytesWritten = 0
        firstCallSeen = false
        log.info("\(category) — closed (\(dataSize) bytes)")
    }

    private static func buildWAVHeader(sampleRate: UInt32,
                                       channels: UInt16,
                                       bitsPerSample: UInt16,
                                       dataSize: UInt32) -> Data {
        var header = Data()
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let fileSize = dataSize &+ 36
        header.append(contentsOf: "RIFF".utf8)
        header.append(uint32LE(fileSize))
        header.append(contentsOf: "WAVE".utf8)
        header.append(contentsOf: "fmt ".utf8)
        header.append(uint32LE(16))
        header.append(uint16LE(1))                // PCM int
        header.append(uint16LE(channels))
        header.append(uint32LE(sampleRate))
        header.append(uint32LE(byteRate))
        header.append(uint16LE(blockAlign))
        header.append(uint16LE(bitsPerSample))
        header.append(contentsOf: "data".utf8)
        header.append(uint32LE(dataSize))
        return header
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var le = v.littleEndian
        return Data(bytes: &le, count: 2)
    }
}
