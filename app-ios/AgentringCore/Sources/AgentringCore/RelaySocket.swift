import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Resumable event stream (`GET /v1/ws?after_seq=`): reconnects with exponential
/// backoff (1 s → 30 s, ±20 % jitter) and resumes from the last `seq` the caller has
/// processed (`lastSeq()` is asked before every connect). With `expectedRelayId`, a
/// server whose `ws.hello` names another relay is dropped and nothing it sends is
/// delivered.
///
/// Every callback runs on the socket's private serial queue, in order; hop to the main
/// actor yourself. `onState(.connected)` comes with the first frame (the relay always
/// opens with `ws.hello`). After `onUnauthorized` or `onWrongRelay` the socket stops
/// reconnecting (`start()` may be called again); `stop()` is final.
public final class RelaySocket: @unchecked Sendable {
    public enum State: Sendable {
        case connecting, connected, disconnected
    }

    private let api: RelayApi
    private let expectedRelayId: String?
    private let makeConnection: @Sendable (URLRequest) -> WebSocketConnection
    private let lastSeq: @Sendable () -> Int64
    private let onEvent: @Sendable (Event) -> Void
    private let onState: @Sendable (State) -> Void
    private let onUnauthorized: @Sendable () -> Void
    private let onWrongRelay: @Sendable (String) -> Void

    private let queue = DispatchQueue(label: "dev.agentring.relay-socket")
    // Everything below is only touched on `queue`.
    private var conn: WebSocketConnection?
    private var retry: DispatchWorkItem?
    private var attempts = 0
    private var running = false
    private var stopped = false
    private var opened = false
    private var awaitingPong = false

    /// Keepalive: a ping every `pingInterval`; no pong by the next one means the
    /// connection is dead (like OkHttp's ping interval on Android).
    let pingInterval: TimeInterval

    public convenience init(
        api: RelayApi,
        expectedRelayId: String?,
        session: URLSession = .shared,
        lastSeq: @escaping @Sendable () -> Int64,
        onEvent: @escaping @Sendable (Event) -> Void,
        onState: @escaping @Sendable (State) -> Void,
        onUnauthorized: @escaping @Sendable () -> Void,
        onWrongRelay: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.init(
            api: api, expectedRelayId: expectedRelayId,
            makeConnection: { URLSessionWebSocketConnection(session.webSocketTask(with: $0)) },
            pingInterval: 20,
            lastSeq: lastSeq, onEvent: onEvent, onState: onState,
            onUnauthorized: onUnauthorized, onWrongRelay: onWrongRelay
        )
    }

    /// Transport seam for tests (Linux's libcurl usually has no WebSocket support).
    init(
        api: RelayApi,
        expectedRelayId: String?,
        makeConnection: @escaping @Sendable (URLRequest) -> WebSocketConnection,
        pingInterval: TimeInterval,
        lastSeq: @escaping @Sendable () -> Int64,
        onEvent: @escaping @Sendable (Event) -> Void,
        onState: @escaping @Sendable (State) -> Void,
        onUnauthorized: @escaping @Sendable () -> Void,
        onWrongRelay: @escaping @Sendable (String) -> Void
    ) {
        self.api = api
        self.expectedRelayId = expectedRelayId
        self.makeConnection = makeConnection
        self.pingInterval = pingInterval
        self.lastSeq = lastSeq
        self.onEvent = onEvent
        self.onState = onState
        self.onUnauthorized = onUnauthorized
        self.onWrongRelay = onWrongRelay
    }

    /// Runs on the socket's queue; silently dropped once the socket is stopped.
    private func post(_ block: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if stopped { return }
            block()
        }
    }

    /// Connects with `after_seq = lastSeq()`. No-op while already running or after `stop()`.
    public func start() {
        post { [self] in
            if running { return }
            running = true
            attempts = 0
            connect()
        }
    }

    /// Closes the connection for good. A stopped socket can't be restarted.
    public func stop() {
        post { [self] in
            running = false
            stopped = true
            retry?.cancel()
            retry = nil
            conn?.cancel(code: 1000, reason: "bye")
            conn = nil
            onState(.disconnected)
        }
    }

    private func connect() {
        guard running else { return }
        retry = nil
        onState(.connecting)
        let c = makeConnection(api.webSocketRequest(afterSeq: lastSeq()))
        conn = c
        opened = false
        awaitingPong = false
        c.resume()
        receive(c)
        schedulePing(c)
    }

    private func receive(_ c: WebSocketConnection) {
        c.receive { [weak self] result in
            guard let self else { return }
            self.post { self.handle(c, result) }
        }
    }

    private func handle(_ c: WebSocketConnection, _ result: Result<String?, Error>) {
        guard conn === c else { return }
        switch result {
        case .failure:
            onDown(c)
        case .success(let text):
            if !opened {
                opened = true
                attempts = 0
                onState(.connected)
            }
            if let text, let event = try? Event.parse(text) {
                if case .wsHello(let hello) = event, let expectedRelayId, hello.relayId != expectedRelayId {
                    wrongRelay(c, hello.relayId)
                    return
                }
                onEvent(event)
            }
            receive(c)
        }
    }

    private func schedulePing(_ c: WebSocketConnection) {
        queue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self, !self.stopped, self.conn === c else { return }
            if self.awaitingPong {
                // No pong since the last ping: the connection is dead.
                c.cancel(code: 1001, reason: nil)
                self.onDown(c)
                return
            }
            self.awaitingPong = true
            c.sendPing { [weak self] error in
                guard let self else { return }
                self.post {
                    guard self.conn === c else { return }
                    if error != nil {
                        c.cancel(code: 1001, reason: nil)
                        self.onDown(c)
                    } else {
                        self.awaitingPong = false
                    }
                }
            }
            self.schedulePing(c)
        }
    }

    private func wrongRelay(_ c: WebSocketConnection, _ relayId: String) {
        running = false
        conn = nil
        c.cancel(code: 1000, reason: "wrong relay")
        onState(.disconnected)
        onWrongRelay(relayId)
    }

    private func onDown(_ c: WebSocketConnection) {
        guard conn === c else { return }
        conn = nil
        onState(.disconnected)
        // Close code 4401 (revoked device / bad token) or an HTTP 401 on the upgrade.
        if c.closeCode == 4401 || c.httpStatus == 401 {
            running = false
            onUnauthorized()
            return
        }
        guard running else { return }
        let delay = Self.backoffDelay(attempt: attempts, random: Double.random(in: 0..<1))
        attempts += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
        retry = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Seconds before reconnect attempt `attempt` (0-based): min(30, 2^attempt) × [0.8, 1.2).
    static func backoffDelay(attempt: Int, random: Double) -> TimeInterval {
        let base = min(30.0, Double(1 << min(attempt, 5)))
        return base * (0.8 + random * 0.4)
    }
}

/// The few WebSocket operations `RelaySocket` needs.
protocol WebSocketConnection: AnyObject, Sendable {
    func resume()
    /// The next frame: its text (nil for a binary frame that isn't UTF-8), or the
    /// error that ended the connection.
    func receive(_ completion: @escaping @Sendable (Result<String?, Error>) -> Void)
    func sendPing(_ completion: @escaping @Sendable (Error?) -> Void)
    func cancel(code: Int, reason: String?)
    /// The close code the server sent, or 0.
    var closeCode: Int { get }
    /// The HTTP status of a refused upgrade, if any.
    var httpStatus: Int? { get }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func resume() { task.resume() }

    func receive(_ completion: @escaping @Sendable (Result<String?, Error>) -> Void) {
        task.receive { result in
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success(.string(let s)):
                completion(.success(s))
            case .success(.data(let d)):
                completion(.success(String(data: d, encoding: .utf8)))
            case .success:
                completion(.success(nil))
            }
        }
    }

    func sendPing(_ completion: @escaping @Sendable (Error?) -> Void) {
        task.sendPing { completion($0) }
    }

    func cancel(code: Int, reason: String?) {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task.cancel(with: closeCode, reason: reason.map { Data($0.utf8) })
    }

    // Apple's CloseCode is an NS_ENUM and keeps application codes such as 4401.
    var closeCode: Int { task.closeCode.rawValue }

    var httpStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }
}
