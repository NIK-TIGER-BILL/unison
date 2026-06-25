import SwiftUI
import Testing
@testable import UnisonDomain
@testable import UnisonUI

@MainActor
struct MeetingHistoryViewSnapshotTests {

    private func seededVM() -> MeetingHistoryViewModel {
        let store = InMemoryMeetingStore()
        func entry(_ s: Speaker, _ orig: String, _ trans: String) -> TranscriptEntry {
            TranscriptEntry(id: UUID(), speaker: s, originalText: orig, translatedText: trans,
                            sourceLanguage: nil, targetLanguage: .ru,
                            timestamp: Date(timeIntervalSince1970: 1_718_000_000))
        }
        store.save(MeetingRecord(id: UUID(), title: "Синк с командой",
            startedAt: Date(timeIntervalSince1970: 1_718_000_000),
            endedAt: Date(timeIntervalSince1970: 1_718_001_920),
            mode: .call, languagePair: LanguagePair(mine: .ru, peer: .en),
            entries: [entry(.peer, "Are we on track for Friday?", "Успеваем к пятнице?"),
                      entry(.me, "Бэкенд готов.", "Backend is done.")],
            pinned: true))
        store.save(MeetingRecord(id: UUID(), title: "Интервью — кандидат",
            startedAt: Date(timeIntervalSince1970: 1_717_900_000),
            endedAt: Date(timeIntervalSince1970: 1_717_903_060),
            mode: .listen, languagePair: LanguagePair(mine: .ru, peer: .en),
            entries: [entry(.peer, "Tell me about a system you designed.",
                            "Расскажите о спроектированной вами системе.")]))
        return MeetingHistoryViewModel(store: store)
    }

    private func panel<V: View>(_ view: V, size: CGSize) -> some View {
        ZStack { Color.black; view }.frame(width: size.width, height: size.height)
    }

    @Test func meetingHistory_populated() throws {
        snapSmoke(panel(MeetingHistoryView(vm: seededVM()), size: SnapSize.history),
                  size: SnapSize.history)
    }

    @Test func meetingHistory_empty() throws {
        // Empty archive — render-only smoke (no committed reference needed).
        snapSmoke(MeetingHistoryView(vm: MeetingHistoryViewModel(store: InMemoryMeetingStore())),
                  size: SnapSize.history)
    }
}
