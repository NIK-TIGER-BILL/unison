import Testing
@testable import UnisonDomain

@Test @MainActor func transcriptStore_appendsNewEntry() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hello", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].translatedText == "Hello")
    #expect(store.entries[0].speaker == .me)
}

@Test @MainActor func transcriptStore_concatenatesDeltas() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "Hello ", isFinal: false))
    store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "world", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].translatedText == "Hello world")
}

@Test @MainActor func transcriptStore_mergesOriginalAndTranslated() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: true))
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hello", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].originalText == "Привет")
    #expect(store.entries[0].translatedText == "Hello")
}

@Test @MainActor func transcriptStore_clears() {
    let store = TranscriptStore()
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "x", isFinal: true))
    store.clear()
    #expect(store.entries.isEmpty)
}

@Test @MainActor func transcriptStore_exportAsText() {
    let store = TranscriptStore()
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "Hi", isFinal: true))
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Hello", isFinal: true))
    let text = store.exportAsText()
    #expect(text.contains("Me:"))
    #expect(text.contains("Peer:"))
    #expect(text.contains("Hi"))
    #expect(text.contains("Hello"))
}

@Test @MainActor func transcriptStore_targetLanguageFollowsSpeakerDirection() {
    let store = TranscriptStore()
    store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .me, kind: .translated, text: "Hello", isFinal: true))
    store.apply(TranscriptDelta(entryId: freshUUID(), speaker: .peer, kind: .translated, text: "Привет", isFinal: true))
    #expect(store.entries.count == 2)
    // .me speaks .ru, translated to .en
    #expect(store.entries[0].speaker == .me)
    #expect(store.entries[0].targetLanguage == .en)
    // .peer speaks .en, translated to .ru
    #expect(store.entries[1].speaker == .peer)
    #expect(store.entries[1].targetLanguage == .ru)
}

@MainActor
@Test func transcriptStore_markEntriesAtRisk_setsFlag() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    #expect(store.entries[0].translationAtRisk == false)
    store.markActiveEntriesAtRisk()
    #expect(store.entries[0].translationAtRisk == true)
}

@MainActor
@Test func transcriptStore_lateTranslationDelta_clearsAtRisk() {
    let store = TranscriptStore()
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    store.markActiveEntriesAtRisk()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hi", isFinal: false))
    #expect(store.entries[0].translationAtRisk == false)
}

@Test @MainActor func transcriptStore_apply_stampsActivityFromClock() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    #expect(store.entries[0].timestamp == epochDate(1000))
    #expect(store.entries[0].lastActivityAt == epochDate(1000))
}

@Test @MainActor func transcriptStore_apply_bumpsLastActivityAtOnLaterDelta() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let id = freshUUID()
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет", isFinal: false))
    clock.advance(by: 7)
    store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hi", isFinal: true))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].lastActivityAt == epochDate(1007)) // bumped to latest delta
    #expect(store.entries[0].timestamp == epochDate(1000))      // creation unchanged
}

// MARK: - Turn-aware bubble assignment (cross-speaker handoff)

/// Each translation stream mints ONE utterance id and rotates it only on
/// its own signals (5 s input-gap or the server's `output_transcript.done`).
/// A stream is blind to the OTHER speaker taking a turn, so when the peer
/// pauses < 5 s while I speak and then resumes, the peer stream REUSES the
/// same id. Without turn-awareness the store retro-appends the resumed
/// speech into the first peer entry — which sits ABOVE my entry in the
/// array — so the peer's new sentence renders in the old bubble over my
/// reply. The resumed utterance must instead start a NEW entry after mine.
@Test @MainActor func transcriptStore_peerResumesAfterMyTurn_startsNewBubble() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    let peerId = freshUUID()
    let meId = freshUUID()

    // 1. Peer speaks (utterance 1) → first peer bubble.
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Hello", isFinal: false))
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .translated, text: "Привет", isFinal: false))

    // 2. I speak → my bubble (already correct today).
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "Как дела", isFinal: false))
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .translated, text: "How are you", isFinal: false))

    // 3. Peer resumes < 5 s later. Its stream never rotated (gap < 5 s, no
    //    server done event) so the delta carries the SAME peerId — but the
    //    peer couldn't see that I took a turn in between.
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "I am fine", isFinal: false))
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .translated, text: "Я в порядке", isFinal: false))

    // Expected order: peer-1, me, peer-2 — the resumed speech in its own bubble.
    #expect(store.entries.count == 3)
    #expect(store.entries[0].speaker == .peer)
    #expect(store.entries[0].originalText == "Hello")
    #expect(store.entries[0].translatedText == "Привет")
    #expect(store.entries[1].speaker == .me)
    #expect(store.entries[2].speaker == .peer)
    #expect(store.entries[2].originalText == "I am fine")
    #expect(store.entries[2].translatedText == "Я в порядке")
}

/// Overlap guard: when both sides talk over each other the same id keeps
/// streaming with no idle gap. That must NOT fragment into a fresh bubble
/// on every alternation — only a genuine handoff (the other speaker spoke
/// AND this entry went quiet) forks.
@Test @MainActor func transcriptStore_rapidOverlap_keepsAppendingNoFork() {
    let clock = FakeClock(now: epochDate(0))
    let store = TranscriptStore(clock: clock)
    let peerId = freshUUID()
    let meId = freshUUID()

    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "a", isFinal: false))
    clock.advance(by: 0.2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "b", isFinal: false))
    clock.advance(by: 0.2) // only 0.4 s since the peer entry last grew — not quiet
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "c", isFinal: false))

    #expect(store.entries.count == 2)
    #expect(store.entries[0].originalText == "ac") // peer entry kept accumulating
    #expect(store.entries[1].speaker == .me)
}

/// IN→OUT lag guard: a translation chunk that merely lagged behind its own
/// source (a normal multi-second delay inside one turn) carries the stale
/// id but must append to its original entry — NOT fork — even after the
/// other speaker interjected and the entry went quiet. Only `.original`
/// starts a new turn.
@Test @MainActor func transcriptStore_laggingTranslationAfterInterjection_appendsNotForks() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    let peerId = freshUUID()
    let meId = freshUUID()

    // Peer's source transcript arrives; its translation has not yet started.
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Bonjour", isFinal: false))
    // I interject.
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "Hi", isFinal: false))
    // Peer's LAGGING translation of utterance 1 finally streams (same id),
    // well past the handoff gap.
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .translated, text: "Привет", isFinal: false))

    // It must join its own original, not spawn a third bubble.
    #expect(store.entries.count == 2)
    #expect(store.entries[0].originalText == "Bonjour")
    #expect(store.entries[0].translatedText == "Привет")
}

/// A cross-speaker handoff after a reused stream id forks a BRAND-NEW entry
/// rather than appending into the reused id, so the resumed speech renders
/// in its own bubble after the interjection instead of the buried one.
@Test @MainActor func transcriptStore_fork_createsNewEntryForResumedUtterance() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let peerId = freshUUID()
    let meId = freshUUID()

    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Hello", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "Hi", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "I am fine", isFinal: false))

    #expect(store.entries.count == 3)
    #expect(store.entries[2].id != peerId)              // a brand-new entry, not the reused id
    #expect(store.entries[2].originalText == "I am fine")
}

/// The handoff "quiet" check must key off the speaker's own INPUT activity,
/// not any delta. A translation of the PREVIOUS peer utterance can lag and
/// land (bumping the entry) just before the peer resumes; if the quiet
/// check counted that translation, the genuinely-new utterance would be
/// appended into the buried bubble — the exact bug this fork prevents,
/// reintroduced through the translation channel. (Reviewer finding.)
@Test @MainActor func transcriptStore_laggingTranslationThenPeerResumes_stillForks() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    let peerId = freshUUID()
    let meId = freshUUID()

    // Peer utterance 1 (source only so far).
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Hello", isFinal: false))
    // I interject.
    clock.advance(by: 1)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "Hi", isFinal: false))
    // Utterance 1's translation lands late (still id=peerId) — bumps the
    // peer entry's activity, but is NOT new input.
    clock.advance(by: 1)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .translated, text: "Привет", isFinal: false))
    // Peer resumes 0.4 s after that lagging translation — but ~2.4 s since
    // its last actual SOURCE delta. This is a real handoff and must fork.
    clock.advance(by: 0.4)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: " bye", isFinal: false))

    #expect(store.entries.count == 3)
    #expect(store.entries[0].originalText == "Hello")     // first bubble untouched
    #expect(store.entries[1].speaker == .me)
    #expect(store.entries[2].speaker == .peer)
    #expect(store.entries[2].originalText == " bye")      // resumed speech in its own bubble
}

/// `clear()` must drop the fork remap. Otherwise a reused stream id from a
/// new session resolves to a dead fork entry, misses, and appends a
/// DUPLICATE-id entry — fragmenting one utterance instead of concatenating.
@Test @MainActor func transcriptStore_clear_resetsForkRemap() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let peerId = freshUUID()
    let meId = freshUUID()

    // Force a fork so the remap holds peerId → fork entry.
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Hello", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "Hi", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Bye", isFinal: false))
    #expect(store.entries.count == 3) // forked

    store.clear()

    // Same stream id, two fragments of one utterance. A surviving remap would
    // route the second fragment to the dead fork id and append a duplicate.
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "New ", isFinal: false))
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "session", isFinal: false))
    #expect(store.entries.count == 1)
    #expect(store.entries[0].originalText == "New session")
}

/// Multiple back-and-forth handoffs (peer→me→peer→me→peer): EACH resumption,
/// on both sides, gets its own bubble in order. Exercises the remap being
/// overwritten per fork rather than re-forking into the wrong entry.
@Test @MainActor func transcriptStore_multipleInterjections_eachResumptionOwnsItsBubble() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let peerId = freshUUID()
    let meId = freshUUID()

    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "P1", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "M1", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "P2", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "M2", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "P3", isFinal: false))

    #expect(store.entries.count == 5)
    #expect(store.entries.map { $0.originalText ?? "" } == ["P1", "M1", "P2", "M2", "P3"])
    #expect(store.entries.map { $0.speaker } == [.peer, .me, .peer, .me, .peer])
}

/// After a fork, the REST of that utterance — further `.original` fragments
/// and its `.translated` — must accumulate into the single fork, not
/// re-match the stale entry or spawn extra bubbles.
@Test @MainActor func transcriptStore_resumedUtterance_accumulatesIntoOneFork() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
    let peerId = freshUUID()
    let meId = freshUUID()

    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "Hi", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "Yo", isFinal: false))
    clock.advance(by: 2)
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "How ", isFinal: false))
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "are you", isFinal: false))
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .translated, text: "Как дела", isFinal: false))

    #expect(store.entries.count == 3)
    #expect(store.entries[0].originalText == "Hi") // first peer bubble untouched
    #expect(store.entries[2].originalText == "How are you")
    #expect(store.entries[2].translatedText == "Как дела")
}

/// Threshold boundary: a handoff gap of exactly `crossSpeakerHandoffGap`
/// (1.0 s since the peer's last source delta) forks.
@Test @MainActor func transcriptStore_handoffGapAtThreshold_forks() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let peerId = freshUUID()
    let meId = freshUUID()
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "A", isFinal: false))
    clock.advance(by: 0.5)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "B", isFinal: false))
    clock.advance(by: 0.5) // exactly 1.0 s since the peer's last source delta
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "C", isFinal: false))
    #expect(store.entries.count == 3)
    #expect(store.entries[2].originalText == "C")
}

/// Threshold boundary: just under the gap stays merged (no fork) — protects
/// fast overlap from fragmenting.
@Test @MainActor func transcriptStore_handoffGapJustUnderThreshold_doesNotFork() {
    let clock = FakeClock(now: epochDate(1000))
    let store = TranscriptStore(clock: clock)
    let peerId = freshUUID()
    let meId = freshUUID()
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "A", isFinal: false))
    clock.advance(by: 0.5)
    store.apply(TranscriptDelta(entryId: meId, speaker: .me, kind: .original, text: "B", isFinal: false))
    clock.advance(by: 0.499) // just under 1.0 s
    store.apply(TranscriptDelta(entryId: peerId, speaker: .peer, kind: .original, text: "C", isFinal: false))
    #expect(store.entries.count == 2)
    #expect(store.entries[0].originalText == "AC")
}
