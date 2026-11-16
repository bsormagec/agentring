import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AgentringCore

final class RelayApiTests: XCTestCase {
    private var server: MiniServer!

    override func setUp() {
        super.setUp()
        server = MiniServer()
    }

    override func tearDown() {
        server.shutdown()
        server = nil
        super.tearDown()
    }

    private func take(file: StaticString = #filePath, line: UInt = #line) throws -> MiniServer.Request {
        try XCTUnwrap(server.takeRequest(), "no request recorded", file: file, line: line)
    }

    func testRelayApiSpeaksTheProtocol() async throws {
        server.enqueue(.http(status: 201, body: """
            {"device_id":"dev_1","device_jwt":"jwt","push_secret":"c2VjcmV0","relay_id":"rly_1","agent_name":"Claude",
             "push_config":{"provider":"apns","apns":{"topic":"dev.agentring.app","via_gateway":false}}}
            """))
        server.enqueue(.http(status: 201, body: #"{"msg_id":"msg_1","from":"user","text":"hi","created_at":5}"#))
        server.enqueue(.http(status: 401, body: #"{"error":{"code":"unauthorized","message":"Device revoked"}}"#))
        server.enqueue(.http(status: 204))

        let base = server.url
        let pair = try await RelayApi(baseUrl: base + "/").pair(PairRequest(
            pairingToken: "pt_x", deviceName: "iPhone", appVersion: "0.1.0",
            apns: ApnsTokens(voipToken: "00ff", environment: "sandbox", topic: "dev.agentring.app")))
        XCTAssertEqual(pair.pushConfig?.apns?.topic, "dev.agentring.app")
        XCTAssertEqual(pair.pushConfig?.apns?.viaGateway, false)
        XCTAssertEqual(pair.deviceJwt, "jwt")
        let r1 = try take()
        XCTAssertEqual(r1.method, "POST")
        XCTAssertEqual(r1.path, "/v1/pair")
        XCTAssertNil(r1.header("Authorization"))
        XCTAssertEqual(r1.header("Content-Type"), "application/json")
        let body = try XCTUnwrap(r1.bodyJson)
        XCTAssertEqual(body["pairing_token"] as? String, "pt_x")
        XCTAssertEqual(body["platform"] as? String, "ios")
        XCTAssertEqual(body["app_version"] as? String, "0.1.0")
        XCTAssertNil(body["fcm_token"])
        let apns = try XCTUnwrap(body["apns"] as? [String: Any])
        XCTAssertEqual(apns as NSDictionary, ["voip_token": "00ff", "environment": "sandbox", "topic": "dev.agentring.app"] as NSDictionary)

        let api = RelayApi(baseUrl: base, deviceJwt: "jwt")
        let m = try await api.postMessage(text: "hi", clientMsgId: "c1")
        XCTAssertEqual(m.msgId, "msg_1")
        XCTAssertFalse(m.fromAgent)
        let r2 = try take()
        XCTAssertEqual(r2.header("Authorization"), "Bearer jwt")
        XCTAssertEqual(r2.header("User-Agent"), "agentring-ios")
        XCTAssertEqual(r2.bodyJson as NSDictionary?, ["text": "hi", "client_msg_id": "c1"] as NSDictionary)

        let e = await assertThrowsAsync(RelayError.self) { try await api.status() }
        XCTAssertEqual(e?.isUnauthorized, true)
        XCTAssertEqual(e?.code, "unauthorized")
        XCTAssertEqual(e?.message, "Device revoked")
        XCTAssertEqual(e?.errorDescription, "Device revoked")
        _ = try take()

        try await api.markRead("msg_9")
        let r4 = try take()
        XCTAssertEqual(r4.method, "POST")
        XCTAssertEqual(r4.path, "/v1/messages/msg_9/read")
        XCTAssertNil(r4.header("Content-Type"), "a bodiless POST must not claim JSON")
        XCTAssertTrue(r4.body.isEmpty)

        let ws = api.webSocketRequest(afterSeq: 42)
        XCTAssertEqual(ws.url?.absoluteString, "ws://127.0.0.1:\(server.port)/v1/ws?after_seq=42")
        XCTAssertEqual(ws.value(forHTTPHeaderField: "Authorization"), "Bearer jwt")
        XCTAssertEqual(RelayApi(baseUrl: "https://relay.example.com/", deviceJwt: "j").webSocketRequest(afterSeq: 0).url?.absoluteString,
                       "wss://relay.example.com/v1/ws?after_seq=0")
    }

    func testNotPairedFailsWithoutARequest() async {
        let e = await assertThrowsAsync(CoreError.self) { try await RelayApi(baseUrl: self.server.url).status() }
        XCTAssertEqual(e, CoreError("Not paired"))
    }

    func testErrorsWithoutTheRelayErrorBody() async {
        server.enqueue(.http(status: 502, body: "<html>bad gateway</html>", headers: ["Content-Type": "text/html"]))
        let api = RelayApi(baseUrl: server.url, deviceJwt: "jwt")
        let e = await assertThrowsAsync(RelayError.self) { try await api.getCall("call_1") }
        XCTAssertEqual(e, RelayError(status: 502, code: "http_502", message: "HTTP 502"))
        XCTAssertEqual(e?.isUnauthorized, false)
    }

    func testJoinCallAndActiveCallInStatus() async throws {
        server.enqueue(.http(status: 200, body: """
            {"relay_id":"rly_1","version":"0.1.0","agent_name":"Claude","agent_online":true,"push_provider":"apns",
             "push_providers":["fcm","apns"],
             "active_call":{"call_id":"call_1","direction":"agent_to_user","state":"active","priority":"normal",
             "agent_name":"Claude","created_at":1,"answered_at":2,"device_id":"dev_2"}}
            """))
        server.enqueue(.http(status: 200, body: #"{"relay_id":"rly_1","version":"0.1.0","agent_name":"Claude","agent_online":true,"push_provider":"fcm","active_call":null}"#))
        server.enqueue(.http(status: 200, body: """
            {"call":{"call_id":"call_1","direction":"agent_to_user","state":"active","priority":"normal","agent_name":"Claude",
             "created_at":1,"answered_at":2,"device_id":"dev_2"},
             "join":{"livekit_url":"wss://r","livekit_token":"t","room":"call_1","identity":"device_dev_1","expires_at":3}}
            """))
        server.enqueue(.http(status: 409, body: #"{"error":{"code":"call_ended","message":"Call is ended"}}"#))

        let api = RelayApi(baseUrl: server.url, deviceJwt: "jwt")
        let status = try await api.status()
        let active = try XCTUnwrap(status.activeCall)
        XCTAssertTrue(active.isJoinable)
        XCTAssertEqual(active.answeredAt, 2)
        XCTAssertEqual(status.pushProviders, ["fcm", "apns"])
        XCTAssertEqual(try take().path, "/v1/status")
        let idle = try await api.status()
        XCTAssertNil(idle.activeCall)
        XCTAssertNil(idle.pushProviders)
        _ = try take()

        let j = try await api.joinCall("call_1")
        XCTAssertEqual(j.join.identity, "device_dev_1")
        let r = try take()
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/calls/call_1/join")
        XCTAssertEqual(r.header("Authorization"), "Bearer jwt")

        let e = await assertThrowsAsync(RelayError.self) { try await api.joinCall("call_1") }
        XCTAssertEqual(e?.status, 409)
        XCTAssertEqual(e?.code, "call_ended")

        let userCall = Call(callId: "call_2", direction: "user_to_agent", state: "active", priority: "normal", agentName: "Claude", createdAt: 1)
        XCTAssertFalse(userCall.isJoinable)
        var ended = userCall
        ended.direction = "agent_to_user"
        ended.state = "ended"
        XCTAssertFalse(ended.isJoinable)
    }

    func testCreateCallToTheAgent() async throws {
        server.enqueue(.http(status: 201, body: """
            {"call":{"call_id":"call_9","direction":"user_to_agent","state":"ringing","priority":"normal","agent_name":"Claude",
             "created_at":1,"device_id":"dev_1"},
             "join":{"livekit_url":"wss://r","livekit_token":"t","room":"call_9","identity":"device_dev_1","expires_at":3}}
            """))
        server.enqueue(.http(status: 201, body: """
            {"call":{"call_id":"call_10","direction":"user_to_agent","state":"ringing","priority":"normal","agent_name":"Claude","created_at":1},
             "join":{"livekit_url":"wss://r","livekit_token":"t","room":"call_10","identity":"device_dev_1","expires_at":3}}
            """))
        server.enqueue(.http(status: 503, body: #"{"error":{"code":"agent_offline","message":"The agent is not connected"}}"#))
        server.enqueue(.http(status: 409, body: #"{"error":{"code":"busy","message":"Another call is ringing or active"}}"#))

        let api = RelayApi(baseUrl: server.url, deviceJwt: "jwt")
        let c = try await api.createCall()
        XCTAssertEqual(c.call.callId, "call_9")
        XCTAssertEqual(c.call.direction, "user_to_agent")
        XCTAssertTrue(c.call.isRinging)
        XCTAssertFalse(c.call.isJoinable)
        XCTAssertEqual(c.join.identity, "device_dev_1")
        let r = try take()
        XCTAssertEqual(r.method, "POST")
        XCTAssertEqual(r.path, "/v1/calls")
        XCTAssertEqual(r.header("Authorization"), "Bearer jwt")
        XCTAssertEqual(r.bodyString, "{}")

        _ = try await api.createCall(reason: "quick question")
        XCTAssertEqual(try take().bodyString, #"{"reason":"quick question"}"#)

        for (status, code) in [(503, "agent_offline"), (409, "busy")] {
            let e = await assertThrowsAsync(RelayError.self) { try await api.createCall() }
            XCTAssertEqual(e?.status, status)
            XCTAssertEqual(e?.code, code)
        }
    }

    func testCallLifecycleAndMessagePaths() async throws {
        let call = #"{"call_id":"call_1","direction":"agent_to_user","state":"ended","priority":"normal","agent_name":"Claude","created_at":1,"ended_at":9,"ended_by":"user","end_reason":"hangup","duration_ms":8}"#
        let join = #"{"call":\#(call),"join":{"livekit_url":"wss://r","livekit_token":"t","room":"call_1","identity":"device_dev_1","expires_at":3}}"#
        server.enqueue(.http(status: 204))
        server.enqueue(.http(status: 200, body: join))
        server.enqueue(.http(status: 200, body: call))
        server.enqueue(.http(status: 200, body: call))
        server.enqueue(.http(status: 200, body: call))
        server.enqueue(.http(status: 200, body: #"{"messages":[{"msg_id":"msg_1","from":"agent","text":"a","created_at":1,"read_at":2}],"has_more":true}"#))
        server.enqueue(.http(status: 200, body: #"{"messages":[],"has_more":false}"#))
        server.enqueue(.http(status: 200, body: #"{"msg_id":"msg_1","from":"agent","text":"a","created_at":1}"#))
        server.enqueue(.http(status: 204))

        let api = RelayApi(baseUrl: server.url, deviceJwt: "jwt")
        try await api.reportRinging("call_1")
        var r = try take()
        XCTAssertEqual("\(r.method) \(r.path)", "POST /v1/calls/call_1/ringing")
        XCTAssertNil(r.header("Content-Type"))
        _ = try await api.acceptCall("call_1")
        XCTAssertEqual(try take().path, "/v1/calls/call_1/accept")
        let declined = try await api.declineCall("call_1")
        XCTAssertEqual(declined.endReason, "hangup")
        XCTAssertEqual(try take().path, "/v1/calls/call_1/decline")
        let ended = try await api.endCall("call_1")
        XCTAssertEqual(ended.durationMs, 8)
        XCTAssertEqual(try take().path, "/v1/calls/call_1/end")
        _ = try await api.getCall("call_1")
        r = try take()
        XCTAssertEqual("\(r.method) \(r.path)", "GET /v1/calls/call_1")

        let page = try await api.listMessages()
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.messages.first?.readAt, 2)
        XCTAssertTrue(page.messages.first?.fromAgent ?? false)
        XCTAssertEqual(try take().path, "/v1/messages?limit=200")
        _ = try await api.listMessages(after: "msg_1", limit: 50)
        XCTAssertEqual(try take().path, "/v1/messages?limit=50&after=msg_1")
        _ = try await api.getMessage("msg_1")
        XCTAssertEqual(try take().path, "/v1/messages/msg_1")

        try await api.updatePushTokens(apns: ApnsTokens(gatewayHandle: "h_123"))
        r = try take()
        XCTAssertEqual("\(r.method) \(r.path)", "POST /v1/device/push-tokens")
        XCTAssertEqual(r.header("Authorization"), "Bearer jwt")
        XCTAssertEqual(r.bodyString, #"{"apns":{"gateway_handle":"h_123"}}"#)
    }

    func testPushGatewayRegister() async throws {
        server.enqueue(.http(status: 200, body: #"{"handle":"h_abc"}"#))
        server.enqueue(.http(status: 429, body: #"{"error":{"code":"rate_limited","message":"Slow down"}}"#))

        let tokens = ApnsTokens(voipToken: "00ff00ff00ff00ff", alertToken: "aabbccddeeff0011", environment: "production",
                                topic: "dev.agentring.app", gatewayHandle: "ignored")
        let handle = try await PushGatewayClient.register(gatewayUrl: server.url + "/", tokens: tokens)
        XCTAssertEqual(handle, "h_abc")
        let r = try take()
        XCTAssertEqual("\(r.method) \(r.path)", "POST /v1/register")
        XCTAssertNil(r.header("Authorization"))
        XCTAssertEqual(r.bodyJson as NSDictionary?, [
            "voip_token": "00ff00ff00ff00ff", "alert_token": "aabbccddeeff0011",
            "environment": "production", "topic": "dev.agentring.app",
        ] as NSDictionary)

        let e = await assertThrowsAsync(RelayError.self) {
            try await PushGatewayClient.register(gatewayUrl: self.server.url, tokens: tokens)
        }
        XCTAssertEqual(e, RelayError(status: 429, code: "rate_limited", message: "Slow down"))

        await assertThrowsAsync(CoreError.self) {
            try await PushGatewayClient.register(gatewayUrl: "http://push.example.com", tokens: tokens)
        }
        await assertThrowsAsync(CoreError.self) {
            try await PushGatewayClient.register(gatewayUrl: self.server.url, tokens: ApnsTokens(voipToken: "00ff00ff00ff00ff"))
        }
        await assertThrowsAsync(CoreError.self) {
            try await PushGatewayClient.register(gatewayUrl: self.server.url, tokens: ApnsTokens(environment: "sandbox", topic: "t"))
        }
    }

    func testCancellationCancelsTheRequest() async throws {
        server.enqueue(.hang)
        let api = RelayApi(baseUrl: server.url, deviceJwt: "jwt")
        let task = Task { try await api.status() }
        try await Task.sleep(nanoseconds: 300_000_000)
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        }
    }
}
