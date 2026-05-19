import Foundation
import Observation
import UnisonDomain

@MainActor
@Observable
public final class TranscriptViewModel {
    public let store: TranscriptStore

    public init(store: TranscriptStore) {
        self.store = store
    }

    public var entries: [TranscriptEntry] { store.entries }

    public func exportAsText() -> String { store.exportAsText() }
}
