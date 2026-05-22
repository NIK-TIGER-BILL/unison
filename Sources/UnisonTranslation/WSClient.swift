import Foundation

public enum WSMessage: Sendable, Equatable {
    case text(String)
    case data(Data)
}

/// Why the WebSocket closed. Carries the raw WS close code plus an optional
/// UTF-8 reason payload so consumers (e.g. `OpenAIRealtimeStream`) can
/// distinguish "auth/policy rejection by server" from "transport blew up".
///
/// The previous shape collapsed every non-normal close to `.abnormal(code:)`
/// or `.error(NSError)`, which made the consumer map *everything* to
/// `.networkLost` — hiding the real reason in user-visible bug reports.
public enum WSCloseReason: Sendable, Equatable {
    /// Code 1000 — normal closure initiated by either peer.
    case normal
    /// Any close that arrived with a known WS close code. `reason` is the
    /// UTF-8 decoded `reason` payload sent by the server (often a JSON
    /// blob from OpenAI explaining the auth/policy failure).
    case abnormal(code: Int, reason: String?)
    /// URLSession surfaced an `Error` (TLS, DNS, connection refused) before
    /// a WebSocket-level close frame was seen.
    case error(NSError)
}

public protocol WSClient: Sendable {
    func connect(url: URL, headers: [String: String]) async throws
    func send(_ message: WSMessage) async throws
    func receive() -> AsyncStream<WSMessage>
    func closeStream() -> AsyncStream<WSCloseReason>
    func close() async
}
