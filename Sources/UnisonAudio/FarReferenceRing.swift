import Synchronization

/// Single-producer / single-consumer lock-free ring of `Int16` samples.
///
/// The render thread (`AVAudioOutputMixer`'s `mainMixerNode` tap) is the
/// **only** producer (`write`); the mic thread (the outgoing pipeline's
/// `task1`) is the **only** consumer (`read`). Indices are monotonically
/// increasing `Int`s masked into the backing buffer — the classic Lamport
/// SPSC queue. No locks, no allocation on either path, so `write` is safe
/// to call from a CoreAudio real-time render callback.
///
/// Capacity is rounded up to a power of two. On overflow `write` keeps the
/// oldest samples already queued and drops the newest (returns a short
/// count); on underrun `read` returns fewer than requested and the caller
/// zero-fills (a missing far block means "no echo reference for this block"
/// → that block is simply not cancelled, which is safe).
final class FarReferenceRing: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutableBufferPointer<Int16>
    private let head = Atomic<Int>(0)   // consumer-owned read cursor
    private let tail = Atomic<Int>(0)   // producer-owned write cursor

    init(capacity: Int = 1 << 15) {
        precondition(capacity > 0, "FarReferenceRing capacity must be positive")
        // Round up to a power of two so `& mask` indexing is valid. The
        // monotonic Int cursors overflow only after ~1.9×10¹¹ s at 48 kHz,
        // so wraparound of the cursors themselves is a non-concern.
        var cap = 1
        while cap < capacity { cap <<= 1 }
        self.capacity = cap
        self.mask = cap - 1
        self.storage = UnsafeMutableBufferPointer<Int16>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0)
    }

    deinit { storage.deallocate() }

    /// Producer. Returns the number of samples actually written (< count on
    /// overflow).
    @discardableResult
    func write(_ src: UnsafeBufferPointer<Int16>) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let free = capacity - (t - h)
        let n = min(src.count, free)
        for i in 0..<n { storage[(t &+ i) & mask] = src[i] }
        tail.store(t &+ n, ordering: .releasing)
        return n
    }

    /// Consumer. Returns the number of samples actually read (< count on
    /// underrun).
    @discardableResult
    func read(into dst: UnsafeMutableBufferPointer<Int16>) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let avail = t - h
        let n = min(dst.count, avail)
        for i in 0..<n { dst[i] = storage[(h &+ i) & mask] }
        head.store(h &+ n, ordering: .releasing)
        return n
    }

    /// Consumer-side reset. Only call when the producer is quiescent
    /// (session start/stop), which the orchestrator guarantees.
    func clear() {
        head.store(tail.load(ordering: .acquiring), ordering: .releasing)
    }
}
