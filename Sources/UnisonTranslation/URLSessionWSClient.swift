import Foundation
import UnisonDomain

/// Production `WSClient` backed by `URLSession.webSocketTask`.
///
/// `URLSessionWebSocketTask` exposes the WS close code + server `reason`
/// payload only via the `URLSessionWebSocketDelegate.didCloseWith` callback
/// — `task.receive()` just throws a generic `NSURLError` once the close
/// is processed, with the actual code lost. So this client wires up a
/// delegate just to surface those values to `closeStream()`.
public final class URLSessionWSClient: NSObject, WSClient, URLSessionWebSocketDelegate, @unchecked Sendable {
    /// Diagnostic logger for close-code mapping decisions. Mirrors to
    /// `~/Library/Logs/Unison/unison.log` and unified logging — see
    /// `UnisonLog`. The user's diagnostic copy pulls from the file.
    private static let log = UnisonLog(category: "URLSessionWSClient")

    private var task: URLSessionWebSocketTask?
    /// Lazily-built `URLSession` so we can install `self` as the delegate.
    /// Stored once and reused; the constructor never receives a session.
    private var session: URLSession!
    /// Pinned to the queue the delegate fires on. Defaults to a serial
    /// queue so callbacks don't race with the receive loop.
    private let delegateQueue: OperationQueue

    private var receiveContinuation: AsyncStream<WSMessage>.Continuation?
    private var closeContinuation: AsyncStream<WSCloseReason>.Continuation?
    private let receiveStreamRef: AsyncStream<WSMessage>
    private let closeReasonStreamRef: AsyncStream<WSCloseReason>

    /// One-shot guard so exactly ONE close reason reaches `closeStream()`
    /// per connection, no matter which path observes the disconnect
    /// first: the delegate's `didCloseWith:`, the receive loop's thrown
    /// error, or a client-initiated `close()`. Without it, a receive
    /// error racing the delegate callback emitted TWO failure events —
    /// the generic `.error(NSError)` then `.abnormal(code:reason:)` —
    /// which made the consumer run its failure handling twice and let
    /// the generic transport noise win the sticky error classification
    /// over the server's actual close reason. Lock-protected because
    /// the three paths run on three different threads.
    private let closeEmitLock = NSLock()
    private var closeEventEmitted = false

    /// Returns `true` exactly once per client instance.
    private func tryMarkCloseEmitted() -> Bool {
        closeEmitLock.lock(); defer { closeEmitLock.unlock() }
        if closeEventEmitted { return false }
        closeEventEmitted = true
        return true
    }

    /// Peek (without claiming) whether a close was already emitted, so the
    /// receive-loop error path can skip its 100ms delegate-race delay on a
    /// client-initiated `close()`.
    private func closeAlreadyEmitted() -> Bool {
        closeEmitLock.lock(); defer { closeEmitLock.unlock() }
        return closeEventEmitted
    }

    public override init() {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "com.unison.app.URLSessionWSClient.delegate"
        self.delegateQueue = q

        var rc: AsyncStream<WSMessage>.Continuation!
        var cc: AsyncStream<WSCloseReason>.Continuation!
        self.receiveStreamRef = AsyncStream { rc = $0 }
        self.closeReasonStreamRef = AsyncStream { cc = $0 }
        self.receiveContinuation = rc
        self.closeContinuation = cc

        super.init()

        // Build the session *after* `super.init` because the delegate is
        // `self`. A default-config session is plenty — we don't need
        // any caching or cookies for the realtime WS endpoint.
        self.session = URLSession(
            configuration: .default,
            delegate: self,
            delegateQueue: q
        )
    }

    public func connect(url: URL, headers: [String: String]) async throws {
        var req = URLRequest(url: url)
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()
        startReceiveLoop()
    }

    public func send(_ message: WSMessage) async throws {
        guard let task else { throw URLError(.notConnectedToInternet) }
        let m: URLSessionWebSocketTask.Message
        switch message {
        case .text(let s): m = .string(s)
        case .data(let d): m = .data(d)
        }
        try await task.send(m)
    }

    public func receive() -> AsyncStream<WSMessage> { receiveStreamRef }
    public func closeStream() -> AsyncStream<WSCloseReason> { closeReasonStreamRef }

    public func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        receiveContinuation?.finish()
        if tryMarkCloseEmitted() {
            closeContinuation?.yield(.normal)
        }
        closeContinuation?.finish()
        // Break the URLSession ↔ delegate reference cycle. `URLSession`
        // strongly retains its delegate (per Apple docs: "the session
        // object keeps a strong reference to this delegate until the
        // session is explicitly invalidated"). Because the delegate
        // is `self`, and `self` holds the session in a stored property,
        // neither side ever deallocates unless we explicitly invalidate.
        // Without this, every reconnect attempt and every stop-restart
        // cycle leaks one URLSession + its operation queue forever.
        // `invalidateAndCancel` is fire-and-forget; we already cancelled
        // the task above, so this just releases the delegate retention.
        session?.invalidateAndCancel()
        session = nil
    }

    private func startReceiveLoop() {
        Task { [weak self] in
            // Socket-level arrival cadence diagnostic. Timed HERE — the moment
            // a frame leaves the OS socket, before any actor / decode / pipeline
            // work — so a big `[ws-rx]` gap is the TRUE network/model cadence,
            // not our processing. Cross-checks `[audio-rx]` (measured later on
            // the stream actor): if they match, the gap is the model; if
            // `[ws-rx]` is smooth but `[audio-rx]` is gappy, it's us. Local var
            // (this loop is the only writer) to stay data-race-free.
            var lastFrameAt: Date?
            while let task = self?.task, task.state == .running {
                do {
                    let msg = try await task.receive()
                    let now = Date()
                    let gapMs = lastFrameAt.map { now.timeIntervalSince($0) * 1000 } ?? 0
                    lastFrameAt = now
                    if gapMs > 400 {
                        Self.log.info("[ws-rx] \(Int(gapMs))ms since previous WS frame AT SOCKET — true network/model gap (before any actor/decode)")
                    }
                    switch msg {
                    case .string(let s): self?.receiveContinuation?.yield(.text(s))
                    case .data(let d): self?.receiveContinuation?.yield(.data(d))
                    @unknown default: break
                    }
                } catch {
                    // Give the delegate's `didCloseWith:` a brief window to
                    // win the one-shot — its typed close code + server
                    // reason payload is strictly richer than the generic
                    // transport NSError this path sees. URLSession does not
                    // guarantee the ordering between the two. BUT skip the
                    // delay when the close was already emitted — a
                    // client-initiated `close()` (the normal Stop path) has
                    // already yielded `.normal`, so the 100ms would just add
                    // dead latency to teardown for no benefit.
                    if self?.closeAlreadyEmitted() != true {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                    let ns = error as NSError
                    if self?.tryMarkCloseEmitted() == true {
                        Self.log.error("receive loop error: domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription)")
                        self?.closeContinuation?.yield(.error(ns))
                    }
                    self?.receiveContinuation?.finish()
                    break
                }
            }
        }
    }

    // MARK: - URLSessionWebSocketDelegate

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Self.log.info("WS open — protocol=\(`protocol` ?? "<none>")")
    }

    public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard tryMarkCloseEmitted() else { return }
        // Decode the server-provided reason payload as UTF-8. OpenAI
        // realtime returns a JSON error message (e.g.
        // `{"error":{"type":"invalid_request_error",...}}`) — we
        // surface the raw string upstream and let the consumer parse.
        let reasonString: String? = {
            guard let data = reason, !data.isEmpty else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        let code = closeCode.rawValue
        // Log level mirrors the close semantics: code 1000 (normal
        // closure) is what we ourselves trigger via stop(), so emitting
        // it at .error makes log scans noisy and misleads operators
        // ("oh look, every stop is errored"). Abnormal closes — auth
        // failures, server-initiated tears, transport drops — stay at
        // .error so they stand out.
        if closeCode == .normalClosure {
            Self.log.info("WS close — code=\(code) reason=\(reasonString ?? "<nil>") (normal)")
            closeContinuation?.yield(.normal)
        } else {
            Self.log.error("WS close — code=\(code) reason=\(reasonString ?? "<nil>")")
            closeContinuation?.yield(.abnormal(code: code, reason: reasonString))
        }
    }
}
