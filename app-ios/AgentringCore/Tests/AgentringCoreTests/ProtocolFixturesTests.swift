import Foundation
import XCTest
@testable import AgentringCore

/// Keeps the Swift models honest against protocol/examples (the same fixtures the
/// relay and the Android app test against).
final class ProtocolFixturesTests: XCTestCase {
    func testEveryEventFixtureParsesToATypedEventAndRoundTrips() throws {
        let files = try Fixtures.files(in: "events")
        XCTAssertGreaterThanOrEqual(files.count, 10)
        for f in files {
            let name = f.lastPathComponent
            let data = try Data(contentsOf: f)
            let original = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], name)
            let ev = try Event.parse(data: data)
            if case .unknown = ev { XCTFail("\(name) parsed as unknown") }
            XCTAssertEqual(original["type"] as? String, ev.type, name)
            XCTAssertEqual(original["id"] as? String, ev.id, name)
            XCTAssertEqual((original["ts"] as? NSNumber)?.int64Value, ev.ts, name)
            XCTAssertEqual((original["seq"] as? NSNumber)?.int64Value, ev.seq, name)

            // Same event through Codable, and re-encoding keeps every field the model knows.
            XCTAssertEqual(try JSONDecoder().decode(Event.self, from: data), ev, name)
            let encoded = try JSONEncoder().encode(ev)
            XCTAssertEqual(try Event.parse(data: encoded), ev, name)
            let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any], name)
            for (k, v) in reencoded {
                XCTAssertTrue(original[k].map { jsonEqual($0, v) } ?? false, "\(name): \(k) changed in the round trip")
            }
            // Only fields the app doesn't model may be dropped.
            let dropped = Set(original.keys).subtracting(reencoded.keys)
            XCTAssertTrue(dropped.isSubset(of: ["device_ids"]), "\(name) lost \(dropped)")
        }
    }

    func testFixtureDetails() throws {
        guard case .msgNew(let msg) = try Event.parse(Fixtures.string("examples/events/msg.new.json")) else {
            return XCTFail("msg.new")
        }
        XCTAssertEqual(msg.text, "Build finished ✅")
        XCTAssertEqual(msg.from, "agent")
        XCTAssertTrue(msg.toMessage().fromAgent)
        XCTAssertEqual(msg.toMessage().createdAt, msg.ts)

        guard case .msgNew(let reply) = try Event.parse(Fixtures.string("examples/events/msg.new.reply.json")) else {
            return XCTFail("msg.new reply")
        }
        XCTAssertEqual(reply.replyTo, "msg_01JB0000000000000000000004")
        XCTAssertFalse(reply.toMessage().fromAgent)

        guard case .callInvite(let invite) = try Event.parse(Fixtures.string("examples/events/call.invite.json")) else {
            return XCTFail("call.invite")
        }
        XCTAssertEqual(invite.priority, "urgent")
        XCTAssertEqual(invite.expiresAt, 1_761_200_030_000)
        XCTAssertEqual(invite.direction, "agent_to_user")

        guard case .callAccept(let accept) = try Event.parse(Fixtures.string("examples/events/call.accept.json")) else {
            return XCTFail("call.accept")
        }
        XCTAssertEqual(accept.deviceId, "dev_01JB0000000000000000000009")
        guard case .callDecline = try Event.parse(Fixtures.string("examples/events/call.decline.json")) else {
            return XCTFail("call.decline")
        }
        guard case .callEnd(let end) = try Event.parse(Fixtures.string("examples/events/call.end.json")) else {
            return XCTFail("call.end")
        }
        XCTAssertEqual(end.durationMs, 90000)
        guard case .wsHello(let hello) = try Event.parse(Fixtures.string("examples/events/ws.hello.json")) else {
            return XCTFail("ws.hello")
        }
        XCTAssertNil(hello.seq)
        XCTAssertEqual(hello.lastSeq, 47)
        guard case .agentPresence(let presence) = try Event.parse(Fixtures.string("examples/events/agent.presence.json")) else {
            return XCTFail("agent.presence")
        }
        XCTAssertTrue(presence.online)
    }

    func testUnknownEventTypesAreTolerated() throws {
        let ev = try Event.parse(#"{"type":"future.thing","id":"evt_1","ts":5,"seq":9,"x":1}"#)
        XCTAssertEqual(ev, .unknown(type: "future.thing", id: "evt_1", ts: 5, seq: 9))
        XCTAssertEqual(ev.seq, 9)
        XCTAssertEqual(try JSONDecoder().decode(Event.self, from: Data(#"{"type":"future.thing","id":"evt_1","ts":5}"#.utf8)),
                       .unknown(type: "future.thing", id: "evt_1", ts: 5, seq: nil))
        XCTAssertEqual(try Event.parse(#"{"type":"x.y"}"#), .unknown(type: "x.y", id: "", ts: 0, seq: nil))
        XCTAssertThrowsError(try Event.parse(#"{"id":"evt_1"}"#))
        XCTAssertThrowsError(try Event.parse("not json"))
        // A known type with a missing required field is an error, not unknown.
        XCTAssertThrowsError(try Event.parse(#"{"type":"msg.new","id":"evt_1","ts":1}"#))
    }

    func testPushFixtures() throws {
        // Every push fixture must be handled: the signature vector, plus any APNs payload
        // (a file named apns-*.json holding an `agentring` object somewhere).
        var apnsChecked = 0
        let vector = try Fixtures.json("examples/push/signature-vector.json")
        let vectorSecret = try XCTUnwrap(vector["push_secret"] as? String)
        for f in try Fixtures.files(in: "push") {
            let name = f.lastPathComponent
            guard name.hasPrefix("apns-") else { continue }
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: f)) as? [String: Any], name)
            guard let payload = Self.findApnsPayload(root) else { continue }
            apnsChecked += 1
            let userInfo = payload as [AnyHashable: Any]
            let fields = try XCTUnwrap(PushVerifier.agentringFields(userInfo), name)
            XCTAssertEqual(fields["v"], "1", name)
            let relayId = try XCTUnwrap(fields["relay_id"], name)
            XCTAssertNotNil(fields["sig"], name)
            let peeked = try XCTUnwrap(PushVerifier.peekEvent(apnsUserInfo: userInfo), "\(name): event does not parse")
            if case .unknown = peeked { XCTFail("\(name): event parsed as unknown") }
            XCTAssertNotNil(payload["aps"] as? [String: Any], "\(name): no aps object")

            // Signed with the fixture's own secret if it names one, else (if at all) with the vector's.
            let secret = (root["push_secret"] as? String) ?? vectorSecret
            switch PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: relayId, pushSecret: secret) {
            case .ok(let ev):
                XCTAssertEqual(ev, peeked, name)
            case .rejected(let reason):
                XCTAssertNil(root["push_secret"], "\(name) names its secret but fails: \(reason)")
                XCTAssertEqual(reason, "bad signature", name)
            }
            XCTAssertEqual(PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: "rly_other", pushSecret: secret),
                           .rejected("payload from a different relay"), name)
        }
        print("checked \(apnsChecked) APNs fixture(s)")
    }

    /// The object that has an `agentring` object: the root, or one nested in it.
    static func findApnsPayload(_ obj: [String: Any]) -> [String: Any]? {
        if obj["agentring"] is [String: Any] { return obj }
        for v in obj.values {
            if let o = v as? [String: Any], let found = findApnsPayload(o) { return found }
        }
        return nil
    }

    func testCallJoinInfoDecodes() throws {
        let j = try JSONDecoder().decode(CallWithJoin.self, from: Data("""
            {"call":{"call_id":"call_1","direction":"agent_to_user","state":"active","priority":"urgent","agent_name":"Claude",
               "created_at":1,"answered_at":2,"device_id":"dev_1","extra":true},
             "join":{"livekit_url":"wss://r","livekit_token":"t","room":"call_1","identity":"device_dev_1","expires_at":3}}
            """.utf8))
        XCTAssertEqual(j.call.state, "active")
        XCTAssertFalse(j.call.isRinging)
        XCTAssertTrue(j.call.isActive)
        XCTAssertEqual(j.join.livekitUrl, "wss://r")
        XCTAssertNil(j.call.endedAt)
    }

    func testPairResponseWithApnsPushConfig() throws {
        let apns = try JSONDecoder().decode(PairResponse.self, from: Data("""
            {"device_id":"dev_1","device_jwt":"jwt","push_secret":"c2VjcmV0","relay_id":"rly_1","agent_name":"Claude",
             "push_config":{"provider":"apns","apns":{"topic":"dev.agentring.app","via_gateway":true,"gateway_url":"https://push.agentring.io"}}}
            """.utf8))
        XCTAssertEqual(apns.pushConfig, PushConfig(provider: "apns", apns: ApnsPushConfig(
            topic: "dev.agentring.app", viaGateway: true, gatewayUrl: "https://push.agentring.io")))

        let fcm = try JSONDecoder().decode(PairResponse.self, from: Data("""
            {"device_id":"dev_1","device_jwt":"jwt","push_secret":"c2VjcmV0","relay_id":"rly_1","agent_name":"Claude",
             "push_config":{"provider":"fcm","fcm":{"project_id":"p","application_id":"a","api_key":"k","sender_id":"2"}}}
            """.utf8))
        XCTAssertEqual(fcm.pushConfig?.provider, "fcm")
        XCTAssertNil(fcm.pushConfig?.apns)

        let none = try JSONDecoder().decode(PairResponse.self, from: Data("""
            {"device_id":"dev_1","device_jwt":"jwt","push_secret":"c2VjcmV0","relay_id":"rly_1","agent_name":"Claude","push_config":null}
            """.utf8))
        XCTAssertNil(none.pushConfig)
    }

    func testOptionalFieldsAreOmittedWhenEncoding() throws {
        let req = PairRequest(pairingToken: "pt_x", deviceName: "iPhone", apns: ApnsTokens(voipToken: "abcd", environment: "sandbox"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["pairing_token", "device_name", "platform", "apns"])
        XCTAssertEqual(obj["platform"] as? String, "ios")
        let apns = try XCTUnwrap(obj["apns"] as? [String: Any])
        XCTAssertEqual(Set(apns.keys), ["voip_token", "environment"])
    }
}
