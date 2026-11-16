import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AgentringCore

private func helloFrame(_ relayId: String) -> String {
    #"{"type":"ws.hello","id":"evt_h","ts":1,"relay_id":"\#(relayId)","last_seq":0,"server_ts":1}"#
}

private let messageFrame = #"{"type":"msg.new","id":"evt_1","ts":1,"seq":1,"msg_id":"msg_1","from":"agent","text":"hi"}"#

/// What a socket reported, plus expectations hooks.
private final class Callbacks: @unchecked Sendable {
    let events = Recorder<Event>()
    let states = Recorder<RelaySocket.State>()
    let wrong = Recorder<String>()
    let unauthorized = Recorder<Void>()
    var onEvent: @Sendable (Event) -> Void = { _ in }
    var onState: @Sendable (RelaySocket.State) -> Void = { _ in }
    var onUnauthorized: @Sendable () -> Void = {}
    var onWrongRelay: @Sendable (String) -> Void = { _ in }
}

// MARK: - State machine, on a scripted transport (runs everywhere)

/// A scripted WebSocket: frames are queued by the test; receive() delivers them in order.
private final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    struct Closed: Error {}

    let request: URLRequest
    private let lock = NSLock()
    private var frames: [Result<String?, Error>] = []
    private var pending: (@Sendable (Result<String?, Error>) -> Void)?
    private var _closeCode = 0
    private var _httpStatus: Int?
    private var _cancelled: Int?
    var answerPings = true

    init(request: URLRequest) { self.request = request }

    var closeCode: Int { lock.lock(); defer { lock.unlock() }; return _closeCode }
    var httpStatus: Int? { lock.lock(); defer { lock.unlock() }; return _httpStatus }
    /// The close code the socket cancelled this connection with.
    var cancelled: Int? { lock.lock(); defer { lock.unlock() }; return _cancelled }

    func send(_ text: String) { deliver(.success(text)) }

    func close(code: Int) {
        lock.lock()
        _closeCode = code
        lock.unlock()
        deliver(.failure(Closed()))
    }

    func refuse(status: Int) {
        lock.lock()
        _httpStatus = status
        lock.unlock()
        deliver(.failure(Closed()))
    }

    private func deliver(_ r: Result<String?, Error>) {
        lock.lock()
        if let p = pending {
            pending = nil
            lock.unlock()
            DispatchQueue.global().async { p(r) }
        } else {
            frames.append(r)
            lock.unlock()
        }
    }

    func resume() {}

    func receive(_ completion: @escaping @Sendable (Result<String?, Error>) -> Void) {
        lock.lock()
        if frames.isEmpty {
            pending = completion
            lock.unlock()
        } else {
            let r = frames.removeFirst()
            lock.unlock()
            DispatchQueue.global().async { completion(r) }
        }
    }

    func sendPing(_ completion: @escaping @Sendable (Error?) -> Void) {
        if answerPings { DispatchQueue.global().async { completion(nil) } }
    }

    func cancel(code: Int, reason: String?) {
        lock.lock()
        _cancelled = code
        lock.unlock()
    }
}

private final class FakeTransport: @unchecked Sendable {
    let connections = Recorder<FakeConnection>()
    let created = Recorder<Date>()
    /// Runs for connection number `n` (0-based) right after it is created.
    var script: (Int, FakeConnection) -> Void = { _, _ in }
    var answerPings = true

    func make(_ req: URLRequest) -> WebSocketConnection {
        let c = FakeConnection(request: req)
        c.answerPings = answerPings
        let n = connections.all.count
        connections.append(c)
        created.append(Date())
        script(n, c)
        return c
    }

    func afterSeqs() -> [String] {
        connections.all.map { c in
            URLComponents(url: c.request.url!, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "after_seq" }?.value ?? "?"
        }
    }
}

final class RelaySocketTests: XCTestCase {
    private func socket(
        _ transport: FakeTransport, _ cb: Callbacks, expected: String?, pingInterval: TimeInterval = 60,
        lastSeq: @escaping @Sendable () -> Int64 = { 0 }
    ) -> RelaySocket {
        RelaySocket(
            api: RelayApi(baseUrl: "https://relay.example.com", deviceJwt: "jwt"),
            expectedRelayId: expected,
            makeConnection: { transport.make($0) },
            pingInterval: pingInterval,
            lastSeq: lastSeq,
            onEvent: { cb.events.append($0); cb.onEvent($0) },
            onState: { cb.states.append($0); cb.onState($0) },
            onUnauthorized: { cb.unauthorized.append(()); cb.onUnauthorized() },
            onWrongRelay: { cb.wrong.append($0); cb.onWrongRelay($0) }
        )
    }

    /// A server that says hello as `helloId`, then sends one message.
    private func socketAgainst(helloId: String, expected: String?) -> (Callbacks, FakeTransport) {
        let transport = FakeTransport()
        transport.script = { _, c in
            c.send(helloFrame(helloId))
            c.send(messageFrame)
        }
        let cb = Callbacks()
        let finished = expectation(description: "msg.new or wrong relay")
        finished.assertForOverFulfill = false
        cb.onEvent = { if case .msgNew = $0 { finished.fulfill() } }
        cb.onWrongRelay = { _ in finished.fulfill() }
        let s = socket(transport, cb, expected: expected)
        s.start()
        wait(for: [finished], timeout: 5)
        Thread.sleep(forTimeInterval: 0.2) // A message after the bad hello would land now.
        s.stop()
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(cb.unauthorized.all.isEmpty, "not unauthorized")
        return (cb, transport)
    }

    func testAServerNamingAnotherRelayIsDroppedAndDeliversNothing() {
        let (cb, transport) = socketAgainst(helloId: "rly_other", expected: "rly_paired")
        XCTAssertEqual(cb.wrong.all, ["rly_other"])
        XCTAssertTrue(cb.events.all.isEmpty, "\(cb.events.all)")
        XCTAssertEqual(transport.connections.all.count, 1, "reconnected to the wrong relay")
        XCTAssertEqual(transport.connections.all.first?.cancelled, 1000)
        // connecting, connected (first frame), disconnected (wrong relay), disconnected (stop)
        XCTAssertEqual(cb.states.all, [.connecting, .connected, .disconnected, .disconnected])
    }

    func testThePairedRelayStaysConnected() throws {
        let (cb, transport) = socketAgainst(helloId: "rly_paired", expected: "rly_paired")
        XCTAssertTrue(cb.wrong.all.isEmpty)
        XCTAssertEqual(cb.events.all.map(\.type), ["ws.hello", "msg.new"])
        XCTAssertEqual(cb.states.all, [.connecting, .connected, .disconnected])
        let req = try XCTUnwrap(transport.connections.all.first?.request)
        XCTAssertEqual(req.url?.absoluteString, "wss://relay.example.com/v1/ws?after_seq=0")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
    }

    func testNoExpectedRelayAcceptsAnyHello() {
        let (cb, _) = socketAgainst(helloId: "rly_any", expected: nil)
        XCTAssertEqual(cb.events.all.map(\.type), ["ws.hello", "msg.new"])
    }

    func testReconnectsWithBackoffAndResumesFromTheLastSeq() {
        let transport = FakeTransport()
        transport.script = { n, c in
            c.send(helloFrame("rly_1"))
            if n == 0 {
                c.send(messageFrame)
                c.close(code: 1001) // server restart
            } else if n == 1 {
                c.close(code: 1006) // dropped again before anything new
            }
        }
        let seq = Box<Int64>(0)
        let cb = Callbacks()
        let hellos = expectation(description: "three hellos")
        hellos.expectedFulfillmentCount = 3
        cb.onEvent = { ev in
            if let s = ev.seq { seq.value = s }
            if case .wsHello = ev { hellos.fulfill() }
        }
        let started = Date()
        let s = socket(transport, cb, expected: "rly_1", lastSeq: { seq.value })
        s.start()
        wait(for: [hellos], timeout: 10)
        // First frame resets the backoff, so both retries wait ~1 s (0.8–1.2 s), not 1 s then 2 s.
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(elapsed, 1.6)
        XCTAssertLessThan(elapsed, 3.5)
        s.stop()
        XCTAssertEqual(transport.afterSeqs(), ["0", "1", "1"])
        XCTAssertEqual(cb.events.all.map(\.type), ["ws.hello", "msg.new", "ws.hello", "ws.hello"])
        XCTAssertTrue(cb.unauthorized.all.isEmpty)
    }

    func testBackoffGrowsWhileNothingConnects() {
        let transport = FakeTransport()
        let third = expectation(description: "third attempt")
        transport.script = { n, c in
            c.close(code: 1006)
            if n == 2 { third.fulfill() }
        }
        let cb = Callbacks()
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [third], timeout: 8) // ~1 s, then ~2 s
        s.stop()
        let t = transport.created.all
        XCTAssertEqual(t.count, 3)
        let first = t[1].timeIntervalSince(t[0]), second = t[2].timeIntervalSince(t[1])
        XCTAssertTrue((0.75...1.6).contains(first), "first retry after \(first) s")
        XCTAssertTrue((1.55...3.0).contains(second), "second retry after \(second) s")
    }

    func testCloseCode4401IsUnauthorizedAndStopsReconnecting() {
        let transport = FakeTransport()
        transport.script = { _, c in
            c.send(helloFrame("rly_1"))
            c.close(code: 4401)
        }
        let cb = Callbacks()
        let unauthorized = expectation(description: "unauthorized")
        cb.onUnauthorized = { unauthorized.fulfill() }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [unauthorized], timeout: 5)
        Thread.sleep(forTimeInterval: 1.5) // longer than the first backoff
        XCTAssertEqual(transport.connections.all.count, 1, "reconnected after 4401")
        XCTAssertEqual(cb.states.all, [.connecting, .connected, .disconnected])
        XCTAssertEqual(cb.events.all.map(\.type), ["ws.hello"])
        s.stop()
    }

    func testHttp401OnUpgradeIsUnauthorized() {
        let transport = FakeTransport()
        transport.script = { _, c in c.refuse(status: 401) }
        let cb = Callbacks()
        let unauthorized = expectation(description: "unauthorized")
        cb.onUnauthorized = { unauthorized.fulfill() }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [unauthorized], timeout: 5)
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(transport.connections.all.count, 1, "reconnected after 401")
        XCTAssertEqual(cb.states.all, [.connecting, .disconnected])
        s.stop()
    }

    func testOtherHttpErrorsOnUpgradeRetry() {
        let transport = FakeTransport()
        transport.script = { n, c in if n == 0 { c.refuse(status: 503) } else { c.send(helloFrame("rly_1")) } }
        let cb = Callbacks()
        let connected = expectation(description: "connected")
        cb.onState = { if $0 == .connected { connected.fulfill() } }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [connected], timeout: 5)
        s.stop()
        XCTAssertEqual(transport.connections.all.count, 2)
        XCTAssertTrue(cb.unauthorized.all.isEmpty)
    }

    func testStartAgainAfterUnauthorized() {
        let transport = FakeTransport()
        transport.script = { n, c in if n == 0 { c.refuse(status: 401) } else { c.send(helloFrame("rly_1")) } }
        let cb = Callbacks()
        let unauthorized = expectation(description: "unauthorized")
        let connected = expectation(description: "connected")
        cb.onUnauthorized = { unauthorized.fulfill() }
        cb.onState = { if $0 == .connected { connected.fulfill() } }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [unauthorized], timeout: 5)
        s.start() // e.g. after re-pairing
        wait(for: [connected], timeout: 5)
        s.stop()
        XCTAssertEqual(transport.connections.all.count, 2)
    }

    func testStopIsFinal() {
        let transport = FakeTransport()
        transport.script = { _, c in c.send(helloFrame("rly_1")) }
        let cb = Callbacks()
        let connected = expectation(description: "connected")
        cb.onState = { if $0 == .connected { connected.fulfill() } }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [connected], timeout: 5)
        s.stop()
        s.stop()
        s.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(cb.states.all, [.connecting, .connected, .disconnected])
        XCTAssertEqual(transport.connections.all.count, 1, "a stopped socket connected again")
        XCTAssertEqual(transport.connections.all.first?.cancelled, 1000)
    }

    func testStopCancelsAPendingReconnect() {
        let transport = FakeTransport()
        transport.script = { _, c in c.close(code: 1006) }
        let cb = Callbacks()
        let down = expectation(description: "down")
        down.assertForOverFulfill = false
        cb.onState = { if $0 == .disconnected { down.fulfill() } }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [down], timeout: 5)
        s.stop()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(transport.connections.all.count, 1)
    }

    func testStartTwiceConnectsOnce() {
        let transport = FakeTransport()
        transport.script = { _, c in c.send(helloFrame("rly_1")) }
        let cb = Callbacks()
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        s.start()
        Thread.sleep(forTimeInterval: 0.3)
        s.stop()
        XCTAssertEqual(transport.connections.all.count, 1)
    }

    func testMalformedAndBinaryFramesAreSkipped() {
        let transport = FakeTransport()
        transport.script = { _, c in
            c.send(helloFrame("rly_1"))
            c.send("not json")
            c.send(#"{"type":"msg.new"}"#)
            c.send(#"{"type":"future.thing","id":"evt_9","ts":1,"seq":2}"#)
            c.send(messageFrame)
        }
        let cb = Callbacks()
        let done = expectation(description: "msg.new")
        cb.onEvent = { if case .msgNew = $0 { done.fulfill() } }
        let s = socket(transport, cb, expected: "rly_1")
        s.start()
        wait(for: [done], timeout: 5)
        s.stop()
        XCTAssertEqual(cb.events.all.map(\.type), ["ws.hello", "future.thing", "msg.new"])
    }

    func testAConnectionThatStopsAnsweringPingsIsReplaced() {
        let transport = FakeTransport()
        transport.answerPings = false
        transport.script = { _, c in c.send(helloFrame("rly_1")) }
        let cb = Callbacks()
        let hellos = expectation(description: "reconnected")
        hellos.expectedFulfillmentCount = 2
        hellos.assertForOverFulfill = false
        cb.onEvent = { if case .wsHello = $0 { hellos.fulfill() } }
        let s = socket(transport, cb, expected: "rly_1", pingInterval: 0.1)
        s.start()
        wait(for: [hellos], timeout: 5)
        s.stop()
        XCTAssertEqual(transport.connections.all.first?.cancelled, 1001)
    }

    func testAnsweredPingsKeepTheConnection() {
        let transport = FakeTransport()
        transport.script = { _, c in c.send(helloFrame("rly_1")) }
        let cb = Callbacks()
        let s = socket(transport, cb, expected: "rly_1", pingInterval: 0.05)
        s.start()
        Thread.sleep(forTimeInterval: 0.6)
        s.stop()
        Thread.sleep(forTimeInterval: 0.1) // stop() reports on the socket's queue
        XCTAssertEqual(transport.connections.all.count, 1)
        XCTAssertEqual(cb.states.all, [.connecting, .connected, .disconnected])
    }

    func testBackoffGrowsToThirtySeconds() {
        XCTAssertEqual(RelaySocket.backoffDelay(attempt: 0, random: 0.5), 1.0, accuracy: 1e-9)
        XCTAssertEqual(RelaySocket.backoffDelay(attempt: 1, random: 0.5), 2.0, accuracy: 1e-9)
        XCTAssertEqual(RelaySocket.backoffDelay(attempt: 4, random: 0.5), 16.0, accuracy: 1e-9)
        XCTAssertEqual(RelaySocket.backoffDelay(attempt: 5, random: 0.5), 30.0, accuracy: 1e-9)
        XCTAssertEqual(RelaySocket.backoffDelay(attempt: 50, random: 0.5), 30.0, accuracy: 1e-9)
        XCTAssertEqual(RelaySocket.backoffDelay(attempt: 0, random: 0), 0.8, accuracy: 1e-9)
        XCTAssertLessThan(RelaySocket.backoffDelay(attempt: 50, random: 0.999_999), 36.0)
    }
}

// MARK: - The real URLSessionWebSocketTask against a local server

/// Skipped where URLSession has no WebSockets (Linux with a libcurl built without `ws`).
final class RelaySocketNetworkTests: XCTestCase {
    private var server: MiniServer!

    override func setUpWithError() throws {
        try super.setUpWithError()
        server = MiniServer()
        try XCTSkipUnless(Self.webSocketsSupported, "URLSessionWebSocketTask is not supported here (libcurl without ws)")
    }

    override func tearDown() {
        server?.shutdown()
        server = nil
        super.tearDown()
    }

    /// Probed once: Linux's FoundationNetworking needs a libcurl with WebSocket support.
    static let webSocketsSupported: Bool = {
        #if canImport(FoundationNetworking)
        let probe = MiniServer()
        defer { probe.shutdown() }
        probe.enqueue(.webSocket([.send("ok")]))
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(probe.port)/")!)
        let result = Box<Bool?>(nil)
        let done = DispatchSemaphore(value: 0)
        task.receive { r in
            if case .success = r { result.value = true } else { result.value = false }
            done.signal()
        }
        task.resume()
        _ = done.wait(timeout: .now() + 5)
        task.cancel(with: .normalClosure, reason: nil)
        return result.value == true
        #else
        return true
        #endif
    }()

    private func makeSocket(_ cb: Callbacks, expected: String?, lastSeq: @escaping @Sendable () -> Int64 = { 0 }) -> RelaySocket {
        RelaySocket(
            api: RelayApi(baseUrl: server.url, deviceJwt: "jwt"),
            expectedRelayId: expected,
            lastSeq: lastSeq,
            onEvent: { cb.events.append($0); cb.onEvent($0) },
            onState: { cb.states.append($0); cb.onState($0) },
            onUnauthorized: { cb.unauthorized.append(()); cb.onUnauthorized() },
            onWrongRelay: { cb.wrong.append($0); cb.onWrongRelay($0) }
        )
    }

    func testThePairedRelayStaysConnected() throws {
        server.enqueue(.webSocket([.send(helloFrame("rly_paired")), .send(messageFrame)]))
        let cb = Callbacks()
        let got = expectation(description: "msg.new")
        cb.onEvent = { if case .msgNew = $0 { got.fulfill() } }
        let s = makeSocket(cb, expected: "rly_paired")
        s.start()
        wait(for: [got], timeout: 10)
        s.stop()
        XCTAssertEqual(cb.events.all.map(\.type), ["ws.hello", "msg.new"])
        let req = try XCTUnwrap(server.takeRequest())
        XCTAssertEqual(req.path, "/v1/ws?after_seq=0")
        XCTAssertEqual(req.header("Authorization"), "Bearer jwt")
        XCTAssertEqual(req.header("Upgrade")?.lowercased(), "websocket")
    }

    func testAServerNamingAnotherRelayIsDropped() {
        server.enqueue(.webSocket([.send(helloFrame("rly_other")), .send(messageFrame)]))
        let cb = Callbacks()
        let wrong = expectation(description: "wrong relay")
        cb.onWrongRelay = { _ in wrong.fulfill() }
        let s = makeSocket(cb, expected: "rly_paired")
        s.start()
        wait(for: [wrong], timeout: 10)
        Thread.sleep(forTimeInterval: 0.3)
        s.stop()
        XCTAssertEqual(cb.wrong.all, ["rly_other"])
        XCTAssertTrue(cb.events.all.isEmpty)
    }

    func testReconnectsAndResumesFromTheLastSeq() throws {
        server.enqueue(.webSocket([.send(helloFrame("rly_1")), .send(messageFrame), .close(code: 1001, reason: "restart")]))
        server.enqueue(.webSocket([.send(helloFrame("rly_1"))]))
        let seq = Box<Int64>(0)
        let cb = Callbacks()
        let hellos = expectation(description: "two hellos")
        hellos.expectedFulfillmentCount = 2
        cb.onEvent = { ev in
            if let s = ev.seq { seq.value = s }
            if case .wsHello = ev { hellos.fulfill() }
        }
        let s = makeSocket(cb, expected: "rly_1", lastSeq: { seq.value })
        s.start()
        wait(for: [hellos], timeout: 10)
        s.stop()
        XCTAssertEqual(try XCTUnwrap(server.takeRequest()).path, "/v1/ws?after_seq=0")
        XCTAssertEqual(try XCTUnwrap(server.takeRequest()).path, "/v1/ws?after_seq=1")
    }

    func testCloseCode4401IsUnauthorized() {
        server.enqueue(.webSocket([.send(helloFrame("rly_1")), .close(code: 4401, reason: "device revoked")]))
        let cb = Callbacks()
        let unauthorized = expectation(description: "unauthorized")
        cb.onUnauthorized = { unauthorized.fulfill() }
        let s = makeSocket(cb, expected: "rly_1")
        s.start()
        wait(for: [unauthorized], timeout: 10)
        s.stop()
    }

    func testHttp401OnUpgradeIsUnauthorized() {
        server.enqueue(.http(status: 401, body: #"{"error":{"code":"unauthorized","message":"Device revoked"}}"#))
        let cb = Callbacks()
        let unauthorized = expectation(description: "unauthorized")
        cb.onUnauthorized = { unauthorized.fulfill() }
        let s = makeSocket(cb, expected: "rly_1")
        s.start()
        wait(for: [unauthorized], timeout: 10)
        s.stop()
    }
}
