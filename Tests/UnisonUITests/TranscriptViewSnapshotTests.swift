import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
struct TranscriptViewSnapshotTests {

    private func makeVM(elapsed: TimeInterval? = nil) -> TranscriptViewModel {
        let store = TranscriptStore()
        let vm = TranscriptViewModel(store: store, orchestrator: nil)
        vm.previewElapsedSeconds = elapsed
        return vm
    }

    private func panel<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height)
    }

    @Test func transcript_empty() throws {
        let vm = makeVM()
        snap(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    @Test func transcript_oneMeBubble() throws {
        let vm = makeVM(elapsed: 12)
        let store = vm.store
        store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
        let id = UUID()
        store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет, как дела?", isFinal: true))
        store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .translated, text: "Hello, how are you?", isFinal: true))
        snap(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    @Test func transcript_multiGroup() throws {
        let vm = makeVM(elapsed: 47)
        let store = vm.store
        store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)

        let id1 = UUID()
        store.apply(TranscriptDelta(entryId: id1, speaker: .me, kind: .original, text: "Привет, можем начать?", isFinal: true))
        store.apply(TranscriptDelta(entryId: id1, speaker: .me, kind: .translated, text: "Hi there, can we start?", isFinal: true))

        let id2 = UUID()
        store.apply(TranscriptDelta(entryId: id2, speaker: .peer, kind: .original, text: "Of course, let's start the meeting.", isFinal: true))
        store.apply(TranscriptDelta(entryId: id2, speaker: .peer, kind: .translated, text: "Конечно, давай начнём встречу.", isFinal: true))

        let id3 = UUID()
        store.apply(TranscriptDelta(entryId: id3, speaker: .me, kind: .original, text: "Отлично. Я подготовил слайды.", isFinal: true))
        store.apply(TranscriptDelta(entryId: id3, speaker: .me, kind: .translated, text: "Great. I have prepared the slides.", isFinal: true))

        snap(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    @Test func transcript_liveTyping() throws {
        let vm = makeVM(elapsed: 9)
        let store = vm.store
        store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
        let id = UUID()
        store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .original, text: "Hi, let's meet tomorrow", isFinal: false))
        store.apply(TranscriptDelta(entryId: id, speaker: .peer, kind: .translated, text: "Привет, давай встретимся", isFinal: false))
        vm.setLive(entryId: id)
        snap(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    /// An entry that was mid-flight when the orchestrator entered
    /// `.paused` / `.reconnecting` gets stamped with `translationAtRisk`.
    /// The bubble renders an italic placeholder + exclamation icon
    /// instead of the missing translated text — visual proof that the
    /// user notices the gap.
    @Test func transcript_bubbleWithLostTranslation() throws {
        let vm = makeVM(elapsed: 14)
        let store = vm.store
        store.currentLanguagePair = LanguagePair(mine: .ru, peer: .en)
        let id = UUID()
        store.apply(TranscriptDelta(entryId: id, speaker: .me, kind: .original, text: "Привет, как дела?", isFinal: false))
        store.markActiveEntriesAtRisk()
        snap(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }
}
