import Foundation

public enum WSMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

public enum WSCloseReason: Sendable, Equatable {
    case normal
    case abnormal(code: Int)
    case error(NSError)
}

public protocol WSClient: Sendable {
    func connect(url: URL, headers: [String: String]) async throws
    func send(_ message: WSMessage) async throws
    func receive() -> AsyncStream<WSMessage>
    func closeStream() -> AsyncStream<WSCloseReason>
    func close() async
}
