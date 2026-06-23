import Foundation
import UnisonDomain

/// Pure-function transcript grouping. Mirrors the JS algorithm in
/// `design/transcript-final/index.html` so the SwiftUI rendering matches
/// the HTML mock exactly.
///
/// - Runs of same-speaker entries collapse into a `BubbleGroup`.
/// - Long messages split at sentence boundaries (`.`, `!`, `?`) into
///   ≤`splitThreshold` character chunks; the first non-empty chunk gets
///   `isFirstInGroup`, the last gets `isLastInGroup`. Text without
///   terminators (or a single oversized sentence) falls back to a length
///   split at whitespace so no chunk ever exceeds the threshold.
/// - `liveEntryId`, when non-nil and matching the very last entry, marks
///   the last bubble of the last group as `isLive` (renders typing dots).
enum TranscriptGrouping {
    static let defaultSplitThreshold = 240

    static func group(
        entries: [TranscriptEntry],
        splitThreshold: Int = defaultSplitThreshold,
        liveEntryId: UUID? = nil
    ) -> [BubbleGroup] {
        guard !entries.isEmpty else { return [] }

        // 1. Bucket entries into runs of the same speaker.
        var runs: [[TranscriptEntry]] = []
        for entry in entries {
            if var last = runs.last, last.last?.speaker == entry.speaker {
                last.append(entry)
                runs[runs.count - 1] = last
            } else {
                runs.append([entry])
            }
        }

        // 2. Build a bubble list per run, then mark first/last/live.
        var groups: [BubbleGroup] = []
        for (runIndex, run) in runs.enumerated() {
            var rawBubbles: [BubbleViewModel] = []
            for entry in run {
                rawBubbles.append(contentsOf: bubbles(for: entry, splitThreshold: splitThreshold))
            }
            guard let first = rawBubbles.first else { continue }
            let last = rawBubbles.last!
            // Mark first and last by re-emitting; replace flags via a new
            // immutable instance (BubbleViewModel is a value type).
            let isLastRun = runIndex == runs.count - 1
            var flagged: [BubbleViewModel] = []
            for (i, b) in rawBubbles.enumerated() {
                let isFirst = (i == 0)
                let isLast = (i == rawBubbles.count - 1)
                let isLive = isLastRun && isLast
                    && liveEntryId != nil
                    && run.last?.id == liveEntryId
                flagged.append(
                    BubbleViewModel(
                        id: b.id,
                        speaker: b.speaker,
                        primaryText: b.primaryText,
                        secondaryText: b.secondaryText,
                        isFirstInGroup: isFirst,
                        isLastInGroup: isLast,
                        isLive: isLive,
                        translationLost: b.translationLost
                    )
                )
            }
            _ = first; _ = last
            groups.append(BubbleGroup(id: flagged[0].id, speaker: run[0].speaker, bubbles: flagged))
        }
        return groups
    }

    /// Entries whose most-recent activity (`lastActivityAt`) is within
    /// `within` seconds of `now`. The transcript recency window's time
    /// filter — keys off activity, not creation, so a long continuous
    /// utterance (one entry, many deltas) stays visible while still
    /// being spoken. Pure; inject `now` in tests.
    static func recentEntries(
        _ entries: [TranscriptEntry],
        now: Date,
        within: TimeInterval
    ) -> [TranscriptEntry] {
        entries.filter { now.timeIntervalSince($0.lastActivityAt) <= within }
    }

    /// Keep only the last `max` bubbles across all groups (the recency
    /// count-cap), re-assembling survivors into speaker-run groups and
    /// re-deriving `isFirstInGroup` / `isLastInGroup`. `isLive`,
    /// `translationLost`, `speaker` and bubble ids are preserved. When
    /// the total bubble count is already ≤ `max`, the input is returned
    /// unchanged (existing flags intact). Pure.
    static func capTail(_ groups: [BubbleGroup], max: Int) -> [BubbleGroup] {
        guard max > 0 else { return [] }
        let flat = groups.flatMap { $0.bubbles }
        guard flat.count > max else { return groups }
        let kept = Array(flat.suffix(max))

        var result: [BubbleGroup] = []
        var run: [BubbleViewModel] = []

        func flush() {
            guard let head = run.first else { return }
            let lastIdx = run.count - 1
            let flagged = run.enumerated().map { i, b in
                BubbleViewModel(
                    id: b.id,
                    speaker: b.speaker,
                    primaryText: b.primaryText,
                    secondaryText: b.secondaryText,
                    isFirstInGroup: i == 0,
                    isLastInGroup: i == lastIdx,
                    isLive: b.isLive,
                    translationLost: b.translationLost
                )
            }
            result.append(BubbleGroup(id: head.id, speaker: head.speaker, bubbles: flagged))
            run = []
        }

        for b in kept {
            if let last = run.last, last.speaker != b.speaker {
                flush()
            }
            run.append(b)
        }
        flush()
        return result
    }

    // MARK: - Private

    /// Expand one `TranscriptEntry` into one or more bubbles.
    /// - For a `.me` entry: primary = `originalText`, secondary = `translatedText`.
    /// - For a `.peer` entry: primary = `translatedText`, secondary = `originalText`.
    /// - Long primary/secondary strings split at sentence boundaries.
    static func bubbles(for entry: TranscriptEntry, splitThreshold: Int) -> [BubbleViewModel] {
        let primaryRaw: String
        let secondaryRaw: String
        switch entry.speaker {
        case .me:
            primaryRaw = entry.originalText ?? ""
            secondaryRaw = entry.translatedText
        case .peer:
            primaryRaw = entry.translatedText
            secondaryRaw = entry.originalText ?? ""
        }
        let primaryParts = splitOnSentence(primaryRaw, threshold: splitThreshold)
        let secondaryParts = splitOnSentence(secondaryRaw, threshold: splitThreshold)
        let n = max(primaryParts.count, secondaryParts.count, 1)
        // An entry's translation is "lost" when the orchestrator
        // flagged it at-risk during a pause/reconnect AND no
        // translation text ever arrived. Matches the store's
        // `markActiveEntriesAtRisk` flag predicate exactly — a
        // partial translation keeps its text on screen rather than
        // being wiped by the placeholder.
        let translationLost = entry.translationAtRisk && entry.translatedText.isEmpty
        // For peer entries where the translation never arrived, the
        // primary slot is empty on EVERY split bubble (peer's primary
        // is `translatedText`). The previous behaviour put the
        // placeholder only on the tail bubble, which left bubbles
        // 0..N-2 rendering an empty Text('') above their secondary
        // (the original) with no indicator that a translation was
        // expected. For peer entries we propagate the flag to all
        // bubbles so the placeholder appears wherever primary would
        // otherwise be blank. For `.me` entries the original behaviour
        // (tail-only) is still correct because the primary slot is
        // `originalText`, which is non-empty per-bubble (review
        // finding #12).
        let propagateToAll = translationLost && entry.speaker == .peer
        var out: [BubbleViewModel] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            // Pad the shorter side with "" — NOT its last chunk. primary
            // and secondary split independently (sentence boundaries
            // rarely line up between a language and its translation), so
            // when one side has fewer chunks the extra bubbles must leave
            // its slot empty. Repeating the last chunk (the old behaviour)
            // rendered the same translation/original in two consecutive
            // bubbles — the visible duplicate the user reported, which
            // cleared only once the lagging side finished streaming and
            // the chunk counts evened out.
            let p = primaryParts[safe: i] ?? ""
            let s = secondaryParts[safe: i] ?? ""
            // Stable derivative id so SwiftUI diffing works across re-groups.
            let bubbleId = derive(entry.id, suffix: i)
            let isLastOfSplit = (i == n - 1)
            let bubbleLost = propagateToAll || (translationLost && isLastOfSplit)
            out.append(
                BubbleViewModel(
                    id: bubbleId,
                    speaker: entry.speaker,
                    primaryText: p,
                    secondaryText: s,
                    isFirstInGroup: false,
                    isLastInGroup: false,
                    isLive: false,
                    translationLost: bubbleLost
                )
            )
        }
        return out
    }

    /// Split a string into chunks ≤ `threshold` characters, breaking
    /// preferentially at sentence-terminator runs (`.`, `!`, `?` plus
    /// trailing whitespace). Text without terminators — or a single
    /// sentence longer than the threshold — is length-split at the
    /// nearest whitespace before the boundary (`hardSplit`), so every
    /// returned chunk respects the threshold. If the string is short
    /// enough, returns a single-element array. Empty strings produce an
    /// empty array (so callers can pad with the previous chunk).
    static func splitOnSentence(_ text: String, threshold: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= threshold { return [trimmed] }

        // Match sentences as `[^.!?]+[.!?]+\s*` — same regex as the JS source.
        let pattern = #"[^.!?]+[.!?]+\s*"#
        let nsText = trimmed as NSString
        var sentences: [String] = []
        var matchedUpTo = 0
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let matches = regex.matches(in: trimmed, range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                sentences.append(nsText.substring(with: m.range))
                matchedUpTo = m.range.location + m.range.length
            }
        }
        // The regex only captures terminator-ended runs — an unterminated
        // trailing fragment ("Привет. а дальше без точки…") would be
        // silently dropped otherwise. Keep it as a final pseudo-sentence.
        if matchedUpTo < nsText.length {
            let rest = nsText.substring(from: matchedUpTo)
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sentences.append(rest)
            }
        }
        if sentences.isEmpty {
            // No terminators at all — pure length split.
            return hardSplit(trimmed, threshold: threshold)
        }

        var chunks: [String] = []
        var buffer = ""
        for s in sentences {
            // If adding this sentence would overflow AND we already have
            // content in the buffer, flush.
            if (buffer + s).count > threshold && !buffer.isEmpty {
                chunks.append(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
                buffer = s
            } else {
                buffer += s
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        if chunks.isEmpty { return hardSplit(trimmed, threshold: threshold) }
        // The sentence loop flushes *before* overflow, so the only way a
        // chunk exceeds the threshold is a single sentence that is itself
        // oversized — length-split those.
        return chunks.flatMap { chunk in
            chunk.count > threshold ? hardSplit(chunk, threshold: threshold) : [chunk]
        }
    }

    /// Length-based fallback for text without usable sentence boundaries.
    /// Breaks at the nearest whitespace at or before the threshold; an
    /// unbroken run longer than the threshold is hard-cut mid-run.
    static func hardSplit(_ text: String, threshold: Int) -> [String] {
        guard threshold > 0 else { return [text] }
        var remaining = Substring(text)
        var parts: [String] = []
        while remaining.count > threshold {
            let limit = remaining.index(remaining.startIndex, offsetBy: threshold)
            let window = remaining[remaining.startIndex..<limit]
            if let breakIdx = window.lastIndex(where: { $0.isWhitespace }) {
                let piece = String(remaining[remaining.startIndex..<breakIdx])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !piece.isEmpty { parts.append(piece) }
                remaining = remaining[remaining.index(after: breakIdx)...]
            } else {
                // No whitespace inside the window — hard cut.
                parts.append(String(window))
                remaining = remaining[limit...]
            }
            // Drop leading whitespace before the next piece.
            while let first = remaining.first, first.isWhitespace {
                remaining = remaining.dropFirst()
            }
        }
        let tail = String(remaining).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [text] : parts
    }

    /// Deterministic child id from the entry id + chunk index, so SwiftUI's
    /// ForEach can diff bubble-by-bubble across re-renders without flicker.
    static func derive(_ parent: UUID, suffix: Int) -> UUID {
        if suffix == 0 { return parent }
        // Mix the suffix into the high bytes of the UUID's bytes.
        var bytes = withUnsafeBytes(of: parent.uuid) { Array($0) }
        let mix = UInt8(suffix & 0xFF)
        bytes[15] ^= mix
        bytes[14] ^= UInt8((suffix >> 8) & 0xFF)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
