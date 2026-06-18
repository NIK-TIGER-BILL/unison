import Foundation
import Network
@testable import UnisonTranslation
@testable import UnisonDomain

/// A `CheckedContinuation` that resumes exactly once no matter how many
/// callers race to resume it (frame-arrival vs. timeout vs. teardown).
/// Without this, the mock server parked raw continuations inside a
/// `withTaskGroup`; when the timeout branch won, `cancelAll()` could not
/// resume the still-parked continuation and the group never returned —
/// a deadlock that wedged the whole serial test run.
private final class OneShotContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<T, Never>?
    init(_ cont: CheckedContinuation<T, Never>) { self.cont = cont }
    func resume(_ value: T) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// In-process WebSocket server that imitates just enough of the OpenAI
/// realtime API to drive `OpenAIRealtimeStream` end-to-end through the
/// real `URLSessionWSClient` transport.
///
/// **Why we need this.** The existing `FakeWSClient` skips the wire
/// entirely — it satisfies the `WSClient` protocol with in-memory
/// streams and never touches `URLSession`. That's perfect for unit
/// tests of `OpenAIRealtimeStream`'s decode/encode logic but it can't
/// catch regressions in the production transport (URL construction,
/// header handling, close-code propagation, the receive-loop's
/// interaction with `URLSessionWebSocketDelegate`). A local `NWListener`
/// with the WebSocket protocol stack on top gives us a real server we
/// can connect to over `URLSessionWebSocketTask` and observe end-to-end.
///
/// **What it implements.** Just the slice the orchestrator exercises:
/// - Accepts a single incoming WS connection at `/v1/realtime/translations`.
/// - Captures every text frame the client sends so the test can assert
///   the request body shape (the `session.update`, the
///   `session.input_audio_buffer.append` frames).
/// - On demand, echoes a canned `session.created` / `session.updated`
///   handshake, then `session.output_audio.delta` and
///   `session.output_transcript.delta` events to drive the orchestrator
///   into `.translating` with real audio frames flowing.
/// - Closes cleanly on `session.close` (echoes `session.closed`).
///
/// **Threading.** `NWListener` callbacks fire on the listener's queue;
/// we serialise mutation behind a `NSLock`. Tests interact via the
/// `await` async API which marshals work back to the queue.
public final class MockOpenAIRealtimeServer: @unchecked Sendable {
    /// Port the listener bound to. Resolved after `start()` returns.
    public private(set) var port: UInt16 = 0
    /// URL the client should connect to. Constructed from `port` so the
    /// test doesn't have to know about endpoint encoding.
    public var url: URL { URL(string: "ws://127.0.0.1:\(port)/v1/realtime/translations?model=gpt-realtime-translate")! }

    /// Every text frame the server received from the client, in order.
    /// Read after the test's act phase to assert request shape.
    public private(set) var receivedTextFrames: [String] = []
    /// Headers seen on the WebSocket upgrade request — captured from the
    /// `additionalHeaders` exposed by `NWProtocolWebSocket.Metadata`.
    /// `URLSessionWebSocketTask` adds `Sec-WebSocket-*` headers itself;
    /// we surface the rest (e.g. `Authorization`).
    public private(set) var receivedHeaders: [String: String] = [:]
    /// `true` once we accepted a connection. Tests can poll this to
    /// know when the client's `connect()` await resolved.
    public private(set) var connectionAccepted = false

    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockOpenAIRealtimeServer")
    private let lock = NSLock()
    private var connection: NWConnection?
    /// Waiters backing `nextClientMessage()`. Each is a one-shot wrapper
    /// so it resumes exactly once — whether the frame arrives, the
    /// timeout fires, or the server stops.
    private var pendingFrameWaiters: [OneShotContinuation<String?>] = []

    /// Synchronous helpers so the async-context `NSLock` warning under
    /// Swift 6 strict concurrency doesn't fire. The actual lock primitive
    /// is unchanged — just routed through a non-async wrapper.
    private func locked<T>(_ block: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return block()
    }

    public init() throws {
        let wsOpts = NWProtocolWebSocket.Options()
        wsOpts.autoReplyPing = true
        let tcpOpts = NWProtocolTCP.Options()
        tcpOpts.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcpOpts)
        params.defaultProtocolStack.applicationProtocols.insert(wsOpts, at: 0)
        params.allowLocalEndpointReuse = true
        // 0 → kernel picks a free port; we read it after start().
        self.listener = try NWListener(using: params, on: .any)
    }

    /// Begin listening and resolve once the kernel has assigned a port.
    public func start() async throws {
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        // Bind and wait for `.ready`.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let p = self?.listener.port?.rawValue {
                        self?.port = p
                    }
                    cont.resume()
                case .failed(let err):
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            self.listener.start(queue: self.queue)
        }
    }

    /// Tear everything down. Idempotent.
    public func stop() {
        listener.cancel()
        let (conn, pending) = locked { () -> (NWConnection?, [OneShotContinuation<String?>]) in
            let c = connection
            connection = nil
            let p = pendingFrameWaiters
            pendingFrameWaiters.removeAll()
            return (c, p)
        }
        conn?.cancel()
        for w in pending { w.resume(nil) }
    }

    // MARK: - Server-side actions used by tests

    /// Push a `session.created` envelope at the connected client.
    public func sendSessionCreated() async {
        let json = #"{"type":"session.created","event_id":"evt_mock_1","session":{"id":"sess_mock","model":"gpt-realtime-translate"}}"#
        await sendText(json)
    }

    /// Push a `session.updated` confirmation. The orchestrator's pipeline
    /// doesn't gate on this but real OpenAI sends it, so emit for realism.
    public func sendSessionUpdated() async {
        let json = #"{"type":"session.updated","event_id":"evt_mock_2","session":{}}"#
        await sendText(json)
    }

    /// Push a translated audio delta. `pcm` is base64'd into the
    /// `delta` field; the orchestrator decodes and emits an
    /// `AudioFrame(format: .int16, sampleRate: 24_000)` downstream.
    public func sendOutputAudioDelta(pcm: Data) async {
        let b64 = pcm.base64EncodedString()
        let json = #"{"type":"session.output_audio.delta","delta":"\#(b64)"}"#
        await sendText(json)
    }

    /// Push a transcript delta.
    public func sendOutputTranscriptDelta(_ text: String) async {
        let escaped = text.replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"{"type":"session.output_transcript.delta","delta":"\#(escaped)"}"#
        await sendText(json)
    }

    /// Push a `session.closed` confirmation. Pair with `closeConnection`
    /// to imitate a clean server-side shutdown.
    public func sendSessionClosed() async {
        let json = #"{"type":"session.closed"}"#
        await sendText(json)
    }

    /// Push a server-side error event. Useful for forcing the orchestrator
    /// down the `.failed(.apiKeyInvalid)` branch via the on-wire event
    /// instead of a WS close.
    public func sendErrorEvent(code: String, message: String = "mock error") async {
        let json = #"{"type":"error","error":{"code":"\#(code)","message":"\#(message)"}}"#
        await sendText(json)
    }

    /// Close the underlying connection with the given WS close code.
    public func closeConnection(code: UInt16 = 1000) async {
        let conn = locked { connection }
        guard let conn else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = NWProtocolWebSocket.CloseCode.protocolCode(.init(rawValue: code) ?? .normalClosure)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // One-shot: `conn.send`'s completion handler may never fire if
            // the peer already tore the socket down (common in the
            // close-before-data race), which would orphan this
            // continuation and hang the test. A 2 s fallback guarantees we
            // always resume.
            let once = OneShotContinuation<Void>(cont)
            conn.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed({ _ in
                once.resume(())
            }))
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                once.resume(())
            }
        }
    }

    /// Block until the next text frame arrives from the client. Resolves
    /// immediately if a frame is already queued. Used by tests to know
    /// when the orchestrator has finished its handshake step.
    public func nextClientMessage(timeout: TimeInterval = 5.0) async -> String? {
        // Slurp any already-received frame.
        let queued: String? = locked {
            if let next = receivedTextFrames.dropFirst(processedFrameCount).first {
                processedFrameCount += 1
                return next
            }
            return nil
        }
        if let queued { return queued }
        // Otherwise park a one-shot waiter that `receiveLoop` resumes when
        // the next frame lands, with a timeout Task that resumes it with
        // nil if no frame arrives. (No `withTaskGroup`: a parked
        // `withCheckedContinuation` there can't be cancelled, so the group
        // would never return after the timeout branch won — the deadlock
        // that wedged the suite.)
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            let waiter = OneShotContinuation<String?>(cont)
            locked { pendingFrameWaiters.append(waiter) }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                // Claim the waiter under the lock so we don't race
                // `receiveLoop`; resume with nil only if still pending.
                let claimed: Bool = self.locked {
                    if let i = self.pendingFrameWaiters.firstIndex(where: { $0 === waiter }) {
                        self.pendingFrameWaiters.remove(at: i)
                        return true
                    }
                    return false
                }
                if claimed { waiter.resume(nil) }
            }
        }
    }

    /// Index into `receivedTextFrames` of the next un-served frame.
    /// `nextClientMessage()` reads and advances this.
    private var processedFrameCount: Int = 0

    // MARK: - Listener internals

    private func accept(_ conn: NWConnection) {
        locked {
            connection = conn
            connectionAccepted = true
        }
        conn.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.locked { self?.connection = nil } }
            if case .cancelled = state { self?.locked { self?.connection = nil } }
        }
        conn.start(queue: queue)
        receiveLoop(on: conn)
    }

    private func receiveLoop(on conn: NWConnection) {
        conn.receiveMessage { [weak self] data, context, isComplete, error in
            guard let self else { return }
            if let context, let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                if let data, !data.isEmpty {
                    let text = String(data: data, encoding: .utf8) ?? ""
                    if meta.opcode == .text {
                        let waiters: [OneShotContinuation<String?>] = self.locked {
                            self.receivedTextFrames.append(text)
                            let w = self.pendingFrameWaiters
                            self.pendingFrameWaiters.removeAll()
                            // Make sure the `nextClientMessage` cursor counts
                            // this frame as already-served when a waiter is
                            // about to resume.
                            if !w.isEmpty {
                                self.processedFrameCount += 1
                            }
                            return w
                        }
                        for w in waiters { w.resume(text) }
                    }
                }
                if meta.opcode == .close {
                    // Echo back a close frame so the URLSession delegate fires.
                    let respMeta = NWProtocolWebSocket.Metadata(opcode: .close)
                    respMeta.closeCode = .protocolCode(.normalClosure)
                    let respCtx = NWConnection.ContentContext(identifier: "close-ack", metadata: [respMeta])
                    conn.send(content: nil, contentContext: respCtx, isComplete: true, completion: .contentProcessed({ _ in }))
                    return
                }
            }
            if error == nil {
                self.receiveLoop(on: conn)
            }
        }
    }

    private func sendText(_ text: String) async {
        let conn = locked { connection }
        guard let conn else { return }
        guard let data = text.data(using: .utf8) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            conn.send(content: data, contentContext: ctx, isComplete: true, completion: .contentProcessed({ _ in
                cont.resume()
            }))
        }
    }
}
