/// Accumulates a stream of variable-length `Int16` chunks and emits
/// fixed-size blocks, carrying the sub-block remainder to the next `push`.
/// Used on the near (mic) path so SpeexDSP always sees exactly `blockSize`
/// samples per `speex_echo_cancellation` call. Single-threaded — owned by
/// the mic consumer task.
struct Int16Reblocker {
    let blockSize: Int
    private var carry: [Int16] = []

    init(blockSize: Int) { self.blockSize = blockSize }

    /// Append `samples` and return every complete block now available.
    mutating func push(_ samples: [Int16]) -> [[Int16]] {
        carry.append(contentsOf: samples)
        var blocks: [[Int16]] = []
        var offset = 0
        while carry.count - offset >= blockSize {
            blocks.append(Array(carry[offset..<offset + blockSize]))
            offset += blockSize
        }
        if offset > 0 { carry.removeFirst(offset) }
        return blocks
    }

    mutating func reset() { carry.removeAll(keepingCapacity: true) }

    var pending: Int { carry.count }
}
