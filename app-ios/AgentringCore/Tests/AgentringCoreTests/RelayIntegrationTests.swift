import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import AgentringCore

/// Talks to a real relay. Skipped unless `AGENTRING_TEST_RELAY_URL` is set; the agent
/// API key comes from `AGENTRING_TEST_API_KEY` (needed to mint a pairing token), e.g.
///
///     AGENTRING_TEST_RELAY_URL=http://127.0.0.1:8080 AGENTRING_TEST_API_KEY=ak_… swift test
final class RelayIntegrationTests: XCTestCase {
    private var relayUrl = ""
    private var apiKey = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        guard let url = env["AGENTRING_TEST_RELAY_URL"], !url.isEmpty else {
            throw XCTSkip("AGENTRING_TEST_RELAY_URL is not set")
        }
        relayUrl = url
        apiKey = try XCTUnwrap(env["AGENTRING_TEST_API_KEY"], "AGENTRING_TEST_API_KEY is required with AGENTRING_TEST_RELAY_URL")
    }

    /// A request as the agent (API key), for what a phone can't do.
    private func agent(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: RelayApi.trimSlash(relayUrl) + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let data = try await HTTP.send(req, body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, session: .shared)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func testPairMessagesCallsAndEvents() async throws {
        let token = try await agent("POST", "/v1/pairing-tokens", body: [:])
        let qr = try QrPayload.parse(try XCTUnwrap(token["qr_payload"] as? String))
        XCTAssertTrue(qr.pairingToken.hasPrefix("pt_"))

        let apns = ApnsTokens(voipToken: "0123456789abcdef0123456789abcdef", alertToken: "fedcba9876543210fedcba9876543210",
                              environment: "sandbox", topic: "dev.agentring.app")
        let pair = try await RelayApi(baseUrl: qr.relayUrl).pair(PairRequest(
            pairingToken: qr.pairingToken, deviceName: "Swift test", appVersion: "0.0.0-test", apns: apns))
        XCTAssertTrue(pair.deviceId.hasPrefix("dev_"))
        XCTAssertNotNil(Crypto.base64UrlDecode(pair.pushSecret))
        if let config = pair.pushConfig {
            XCTAssertEqual(config.provider, "apns", "an iOS pair must not get the FCM config")
        }

        let api = RelayApi(baseUrl: qr.relayUrl, deviceJwt: pair.deviceJwt)
        let status = try await api.status()
        XCTAssertEqual(status.relayId, pair.relayId)
        XCTAssertEqual(status.agentName, pair.agentName)
        try await api.updatePushTokens(apns: apns)

        // Pairing a second time with the same token fails with the relay's error body.
        let reused = await assertThrowsAsync(RelayError.self) {
            try await RelayApi(baseUrl: qr.relayUrl).pair(PairRequest(pairingToken: qr.pairingToken, deviceName: "again"))
        }
        XCTAssertNotNil(reused?.code)

        let mine = try await api.postMessage(text: "hello from Swift", clientMsgId: UUID().uuidString)
        XCTAssertEqual(mine.from, Message.fromUserValue)
        let theirs = try await agent("POST", "/v1/messages", body: ["text": "hello from the agent"])
        let theirId = try XCTUnwrap(theirs["msg_id"] as? String)
        let page = try await api.listMessages()
        XCTAssertTrue(page.messages.contains { $0.msgId == mine.msgId })
        let fetched = try await api.getMessage(theirId)
        XCTAssertTrue(fetched.fromAgent)
        try await api.markRead(theirId)

        // No agent is connected: calling it fails cleanly (or rings, if one is).
        do {
            let call = try await api.createCall(reason: "integration test")
            XCTAssertNoThrow(try RelayUrlPolicy.checkLiveKit(call.join.livekitUrl))
            _ = try await api.endCall(call.call.callId)
        } catch let e as RelayError {
            XCTAssertTrue(["agent_offline", "calls_unavailable", "busy"].contains(e.code), e.code)
        }

        if RelaySocketNetworkTests.webSocketsSupported {
            let events = Recorder<Event>()
            let gotMessage = expectation(description: "msg.new from the agent over the socket")
            gotMessage.assertForOverFulfill = false
            let socket = RelaySocket(
                api: api, expectedRelayId: pair.relayId, lastSeq: { 0 },
                onEvent: { ev in
                    events.append(ev)
                    if case .msgNew(let m) = ev, m.msgId == theirId { gotMessage.fulfill() }
                },
                onState: { _ in },
                onUnauthorized: { XCTFail("unauthorized") }
            )
            socket.start()
            await fulfillment(of: [gotMessage], timeout: 10)
            socket.stop()
            XCTAssertEqual(events.all.first?.type, "ws.hello")
        }

        let bad = await assertThrowsAsync(RelayError.self) { try await RelayApi(baseUrl: qr.relayUrl, deviceJwt: "nope").status() }
        XCTAssertEqual(bad?.isUnauthorized, true)
    }
}
