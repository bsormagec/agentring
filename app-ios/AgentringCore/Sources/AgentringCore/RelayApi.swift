import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the relay REST API, as a device. All calls are `async throws`: a
/// `RelayError` for HTTP errors (with the relay's `{"error":{"code","message"}}`),
/// `CoreError` when not paired, otherwise `URLError` / `DecodingError`.
public final class RelayApi: @unchecked Sendable {
    public let baseUrl: String
    private let deviceJwt: String?
    private let session: URLSession
    static let userAgent = "agentring-ios"

    public init(baseUrl: String, deviceJwt: String? = nil, session: URLSession = .shared) {
        self.baseUrl = baseUrl
        self.deviceJwt = deviceJwt
        self.session = session
    }

    private struct PushTokensBody: Encodable {
        let apns: ApnsTokens
    }

    private struct PostMessageBody: Encodable {
        let text: String
        let replyTo: String?
        let clientMsgId: String?

        enum CodingKeys: String, CodingKey {
            case text
            case replyTo = "reply_to"
            case clientMsgId = "client_msg_id"
        }
    }

    private struct CreateCallBody: Encodable {
        let reason: String?
    }

    /// Pairs this phone (no auth; the pairing token is in the body).
    public func pair(_ req: PairRequest) async throws -> PairResponse {
        try await call("POST", "/v1/pair", body: req, auth: false)
    }

    /// Replaces this device's APNs registration (direct tokens or a gateway handle).
    public func updatePushTokens(apns: ApnsTokens) async throws {
        try await callNoContent("POST", "/v1/device/push-tokens", body: PushTokensBody(apns: apns))
    }

    public func status() async throws -> Status {
        try await call("GET", "/v1/status")
    }

    public func listMessages(after: String? = nil, limit: Int = 200) async throws -> MessagePage {
        var path = "/v1/messages?limit=\(limit)"
        if let after { path += "&after=\(Self.queryEscape(after))" }
        return try await call("GET", path)
    }

    public func getMessage(_ msgId: String) async throws -> Message {
        try await call("GET", "/v1/messages/\(Self.pathEscape(msgId))")
    }

    public func postMessage(text: String, replyTo: String? = nil, clientMsgId: String? = nil) async throws -> Message {
        try await call("POST", "/v1/messages", body: PostMessageBody(text: text, replyTo: replyTo, clientMsgId: clientMsgId))
    }

    public func markRead(_ msgId: String) async throws {
        try await callNoContent("POST", "/v1/messages/\(Self.pathEscape(msgId))/read")
    }

    /// Calls the agent (M4, direction `user_to_agent`). The relay returns this phone's
    /// LiveKit join info right away; the call rings until the agent accepts. Fails with
    /// 503 `agent_offline` / `calls_unavailable` or 409 `busy`.
    public func createCall(reason: String? = nil) async throws -> CallWithJoin {
        try await call("POST", "/v1/calls", body: CreateCallBody(reason: reason))
    }

    public func getCall(_ callId: String) async throws -> Call {
        try await call("GET", "/v1/calls/\(Self.pathEscape(callId))")
    }

    /// Tells the relay this device is showing the incoming call (measures ring latency).
    public func reportRinging(_ callId: String) async throws {
        try await callNoContent("POST", "/v1/calls/\(Self.pathEscape(callId))/ringing")
    }

    /// Answers a ringing call; after the ring window it fails with 409 `invalid_state` (use `joinCall`).
    public func acceptCall(_ callId: String) async throws -> CallWithJoin {
        try await call("POST", "/v1/calls/\(Self.pathEscape(callId))/accept")
    }

    /// Joins an agent call that is ringing or active, also after this phone's ring ended,
    /// it declined or it hung up. 409 `call_ended` once the call is over.
    public func joinCall(_ callId: String) async throws -> CallWithJoin {
        try await call("POST", "/v1/calls/\(Self.pathEscape(callId))/join")
    }

    public func declineCall(_ callId: String) async throws -> Call {
        try await call("POST", "/v1/calls/\(Self.pathEscape(callId))/decline")
    }

    public func endCall(_ callId: String) async throws -> Call {
        try await call("POST", "/v1/calls/\(Self.pathEscape(callId))/end")
    }

    /// The upgrade request for `GET /v1/ws?after_seq=…` (ws:// or wss://, device JWT).
    public func webSocketRequest(afterSeq: Int64) -> URLRequest {
        var base = Self.trimSlash(baseUrl)
        if base.hasPrefix("https://") {
            base = "wss://" + base.dropFirst("https://".count)
        } else if base.hasPrefix("http://") {
            base = "ws://" + base.dropFirst("http://".count)
        }
        var req = URLRequest(url: URL(string: "\(base)/v1/ws?after_seq=\(afterSeq)")!)
        if let deviceJwt { req.setValue("Bearer \(deviceJwt)", forHTTPHeaderField: "Authorization") }
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    // MARK: - Plumbing

    private func call<Out: Decodable>(_ method: String, _ path: String, auth: Bool = true) async throws -> Out {
        let data = try await send(method, path, body: nil, auth: auth)
        return try JSONDecoder().decode(Out.self, from: data)
    }

    private func call<In: Encodable, Out: Decodable>(_ method: String, _ path: String, body: In, auth: Bool = true) async throws -> Out {
        let data = try await send(method, path, body: try JSONEncoder().encode(body), auth: auth)
        return try JSONDecoder().decode(Out.self, from: data)
    }

    private func callNoContent(_ method: String, _ path: String) async throws {
        _ = try await send(method, path, body: nil, auth: true)
    }

    private func callNoContent<In: Encodable>(_ method: String, _ path: String, body: In) async throws {
        _ = try await send(method, path, body: try JSONEncoder().encode(body), auth: true)
    }

    private func send(_ method: String, _ path: String, body: Data?, auth: Bool) async throws -> Data {
        guard let url = URL(string: Self.trimSlash(baseUrl) + path) else { throw CoreError("Invalid relay URL") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        if auth {
            guard let deviceJwt else { throw CoreError("Not paired") }
            req.setValue("Bearer \(deviceJwt)", forHTTPHeaderField: "Authorization")
        }
        return try await HTTP.send(req, body: body, session: session)
    }

    static func trimSlash(_ s: String) -> String {
        var s = Substring(s)
        while s.hasSuffix("/") { s = s.dropLast() }
        return String(s)
    }

    private static let unreservedChars = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Ids are plain `[A-Za-z0-9_]`, but never let one change the path or the query.
    static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreservedChars) ?? s
    }

    static func queryEscape(_ s: String) -> String { pathEscape(s) }
}

/// Shared HTTP plumbing for the relay and the push gateway.
enum HTTP {
    /// Sends `req` with an optional JSON body. Non-2xx answers throw `RelayError`.
    static func send(_ request: URLRequest, body: Data?, session: URLSession) async throws -> Data {
        var req = request
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        // No body and no Content-Type for bodiless POSTs: the relay (Fastify) rejects an
        // empty body declared as JSON.
        let (data, response) = try await perform(req, session: session)
        guard let http = response as? HTTPURLResponse else { throw CoreError("Not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(ApiErrorBody.self, from: data).error
            throw RelayError(
                status: http.statusCode,
                code: detail?.code ?? "http_\(http.statusCode)",
                message: detail?.message ?? "HTTP \(http.statusCode)"
            )
        }
        return data
    }

    /// `dataTask` wrapped for async/await, cancellable, on Apple platforms and Linux alike.
    private static func perform(_ req: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse), Error>) in
                let task = session.dataTask(with: req) { data, response, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let response {
                        cont.resume(returning: (data ?? Data(), response))
                    } else {
                        cont.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        func set(_ t: URLSessionTask) {
            lock.lock()
            task = t
            let c = cancelled
            lock.unlock()
            if c { t.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let t = task
            lock.unlock()
            t?.cancel()
        }
    }
}
