import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
struct TranscriptViewSnapshotTests {

    private func makeVM(elapsed: TimeInterval? = nil) -> TranscriptViewModel {
        let vm = TranscriptViewModel(model: TranscriptModel(), orchestrator: nil)
        vm.previewElapsedSeconds = elapsed
        return vm
    }

    /// Build a display bubble the way the VM maps a `TranscriptBubble`:
    /// `.me` shows the original as primary; `.peer` shows the translation.
    private func bubble(_ speaker: Speaker, original: String, translated: String,
                        isLive: Bool = false, translationLost: Bool = false) -> DisplayBubble {
        DisplayBubble(
            id: UUID(), speaker: speaker,
            primaryText: speaker == .me ? original : translated,
            secondaryText: speaker == .me ? translated : original,
            isLive: isLive, translationLost: translationLost, lastActivityAt: Date())
    }

    private func panel<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack {
            Color.black
            view
        }
        .frame(width: size.width, height: size.height)
    }

    // All transcript cases are smoke-only. The floating transcript renders
    // on a transparent (`.clear`) host window, and that window's offscreen
    // capture is non-portable: `bitmapImageRepForCachingDisplay` composites
    // the alpha BIMODALLY across machines (fully transparent on one, opaque
    // on another), so no committed PNG matches every environment — the
    // bubble references passed locally but failed on the CI runner. The
    // opaque glass cards (popover / settings / onboarding / diagnostic)
    // fill their frame and DO capture deterministically, so those keep full
    // pixel snapshots. Here we assert the view builds, lays out at the
    // expected size, and renders a non-empty buffer without crashing — see
    // `snapSmoke`.
    @Test func transcript_empty() throws {
        let vm = makeVM()
        snapSmoke(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    @Test func transcript_oneMeBubble() throws {
        let vm = makeVM(elapsed: 12)
        vm.previewBubbles = [bubble(.me, original: "Привет, как дела?", translated: "Hello, how are you?")]
        snapSmoke(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    @Test func transcript_multiGroup() throws {
        let vm = makeVM(elapsed: 47)
        vm.previewBubbles = [
            bubble(.me, original: "Привет, можем начать?", translated: "Hi there, can we start?"),
            bubble(.peer, original: "Of course, let's start the meeting.",
                   translated: "Конечно, давай начнём встречу."),
            bubble(.me, original: "Отлично. Я подготовил слайды.",
                   translated: "Great. I have prepared the slides.")
        ]
        snapSmoke(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    @Test func transcript_liveTyping() throws {
        let vm = makeVM(elapsed: 9)
        // No terminator yet + still forming → the live (typing-dots) bubble.
        vm.previewBubbles = [bubble(.peer, original: "Hi, let's meet tomorrow",
                                    translated: "Привет, давай встретимся", isLive: true)]
        snapSmoke(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }

    /// A segment that committed with the translation missing renders an italic
    /// placeholder + exclamation icon instead of the absent translated text —
    /// visual proof that the user notices the gap.
    @Test func transcript_bubbleWithLostTranslation() throws {
        let vm = makeVM(elapsed: 14)
        vm.previewBubbles = [bubble(.me, original: "Привет, как дела?", translated: "",
                                    translationLost: true)]
        snapSmoke(panel(TranscriptView(vm: vm), size: SnapSize.transcript), size: SnapSize.transcript)
    }
}
