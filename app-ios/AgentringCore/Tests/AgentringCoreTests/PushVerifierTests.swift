import Foundation
import XCTest
@testable import AgentringCore

final class PushVerifierTests: XCTestCase {
    private func vector() throws -> (secret: String, data: [String: String]) {
        let v = try Fixtures.json("examples/push/signature-vector.json")
        let secret = try XCTUnwrap(v["push_secret"] as? String)
        let data = try XCTUnwrap(v["data"] as? [String: String])
        return (secret, data)
    }

    func testPushSignatureMatchesTheSharedTestVector() throws {
        let (secret, data) = try vector()
        let relayId = try XCTUnwrap(data["relay_id"])
        XCTAssertEqual(PushVerifier.sign(pushSecret: secret, eventJson: try XCTUnwrap(data["event"])), data["sig"])

        guard case .ok(let ev) = PushVerifier.verify(data, expectedRelayId: relayId, pushSecret: secret) else {
            return XCTFail("vector rejected")
        }
        guard case .msgNew(let msg) = ev else { return XCTFail("not msg.new") }
        XCTAssertEqual(msg.text, "Build finished ✅")

        XCTAssertEqual(PushVerifier.verify(data, expectedRelayId: "rly_other", pushSecret: secret),
                       .rejected("payload from a different relay"))
        var tampered = data
        tampered["event"] = data["event"]!.replacingOccurrences(of: "Build", with: "Evil")
        XCTAssertEqual(PushVerifier.verify(tampered, expectedRelayId: relayId, pushSecret: secret), .rejected("bad signature"))
        var noSig = data
        noSig["sig"] = nil
        XCTAssertEqual(PushVerifier.verify(noSig, expectedRelayId: relayId, pushSecret: secret), .rejected("missing signature"))
        var noEvent = data
        noEvent["event"] = nil
        XCTAssertEqual(PushVerifier.verify(noEvent, expectedRelayId: relayId, pushSecret: secret), .rejected("missing event"))
        var v2 = data
        v2["v"] = "2"
        XCTAssertEqual(PushVerifier.verify(v2, expectedRelayId: relayId, pushSecret: secret),
                       .rejected("unsupported payload version 2"))
        var noV = data
        noV["v"] = nil
        XCTAssertEqual(PushVerifier.verify(noV, expectedRelayId: relayId, pushSecret: secret),
                       .rejected("unsupported payload version null"))
        // Another secret, an empty signature, a padded signature: all rejected.
        XCTAssertEqual(PushVerifier.verify(data, expectedRelayId: relayId, pushSecret: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
                       .rejected("bad signature"))
        var emptySig = data
        emptySig["sig"] = ""
        XCTAssertEqual(PushVerifier.verify(emptySig, expectedRelayId: relayId, pushSecret: secret), .rejected("bad signature"))
        var padded = data
        padded["sig"] = data["sig"]! + "="
        XCTAssertEqual(PushVerifier.verify(padded, expectedRelayId: relayId, pushSecret: secret), .rejected("bad signature"))
        XCTAssertEqual(PushVerifier.verify(data, expectedRelayId: relayId, pushSecret: "not+base64url/"),
                       .rejected("invalid push secret"))
    }

    func testSignedButMalformedEventIsRejected() throws {
        let (secret, data) = try vector()
        var bad = data
        bad["event"] = #"{"type":"msg.new","id":"evt_1"}"#
        bad["sig"] = PushVerifier.sign(pushSecret: secret, eventJson: bad["event"]!)
        guard case .rejected(let reason) = PushVerifier.verify(bad, expectedRelayId: data["relay_id"]!, pushSecret: secret) else {
            return XCTFail("accepted a malformed event")
        }
        XCTAssertTrue(reason.hasPrefix("malformed event"), reason)
    }

    func testApnsUserInfoVerification() throws {
        let (secret, data) = try vector()
        let relayId = data["relay_id"]!

        // As PushKit / UNNotification hand it over: [AnyHashable: Any] with a nested dictionary.
        let userInfo: [AnyHashable: Any] = ["aps": [String: Any](), "agentring": data as [String: Any]]
        guard case .ok(.msgNew(let msg)) = PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: relayId, pushSecret: secret) else {
            return XCTFail("APNs payload rejected")
        }
        XCTAssertEqual(msg.msgId, "msg_01JB0000000000000000000004")

        // The nested object may also come as [AnyHashable: Any].
        var nested: [AnyHashable: Any] = [:]
        for (k, v) in data { nested[AnyHashable(k)] = v }
        let userInfo2: [AnyHashable: Any] = ["aps": ["alert": ["title": "Claude", "body": "New message"]], "agentring": nested]
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: userInfo2, expectedRelayId: relayId, pushSecret: secret),
                       PushVerifier.verify(data, expectedRelayId: relayId, pushSecret: secret))

        // Decoded straight from the JSON body APNs delivers.
        let body = try JSONSerialization.data(withJSONObject: ["aps": [String: Any](), "agentring": data])
        let fromJson = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: fromJson, expectedRelayId: relayId, pushSecret: secret),
                       PushVerifier.verify(data, expectedRelayId: relayId, pushSecret: secret))

        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: ["aps": [String: Any]()], expectedRelayId: relayId, pushSecret: secret),
                       .rejected("missing agentring payload"))
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: ["agentring": "nope"], expectedRelayId: relayId, pushSecret: secret),
                       .rejected("missing agentring payload"))
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: "rly_other", pushSecret: secret),
                       .rejected("payload from a different relay"))
        var tampered = data
        tampered["event"] = data["event"]!.replacingOccurrences(of: "Build", with: "Evil")
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: ["aps": [String: Any](), "agentring": tampered],
                                           expectedRelayId: relayId, pushSecret: secret),
                       .rejected("bad signature"))
        // Non-string values are ignored, not coerced.
        var numericV: [String: Any] = data
        numericV["v"] = 1
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: ["agentring": numericV], expectedRelayId: relayId, pushSecret: secret),
                       .rejected("unsupported payload version null"))
    }

    func testPeekEventDoesNotVerify() throws {
        let invite = try Fixtures.string("examples/events/call.invite.json")
        let userInfo: [AnyHashable: Any] = [
            "aps": [String: Any](),
            "agentring": ["v": "1", "relay_id": "rly_x", "event": invite, "sig": "forged"],
        ]
        guard case .callInvite(let ev) = PushVerifier.peekEvent(apnsUserInfo: userInfo) else {
            return XCTFail("peek failed")
        }
        XCTAssertEqual(ev.callId, "call_01JB0000000000000000000002")
        XCTAssertEqual(ev.agentName, "Claude")
        XCTAssertEqual(PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: "rly_x", pushSecret: "c2VjcmV0"),
                       .rejected("bad signature"))

        XCTAssertNil(PushVerifier.peekEvent(apnsUserInfo: [:]))
        XCTAssertNil(PushVerifier.peekEvent(apnsUserInfo: ["agentring": ["v": "1"]]))
        XCTAssertNil(PushVerifier.peekEvent(apnsUserInfo: ["agentring": ["event": "{not json"]]))
    }

    func testBase64Url() {
        XCTAssertEqual(Crypto.base64UrlEncode([0xfb, 0xff]), "-_8")
        XCTAssertEqual(Crypto.base64UrlDecode("-_8"), [0xfb, 0xff])
        XCTAssertEqual(Crypto.base64UrlDecode("-_8="), [0xfb, 0xff])
        XCTAssertNil(Crypto.base64UrlDecode("+/8"))
        XCTAssertNil(Crypto.base64UrlDecode("a"))
        XCTAssertEqual(Crypto.base64UrlDecode(""), [])
        XCTAssertTrue(Crypto.constantTimeEquals([1, 2, 3], [1, 2, 3]))
        XCTAssertFalse(Crypto.constantTimeEquals([1, 2, 3], [1, 2, 4]))
        XCTAssertFalse(Crypto.constantTimeEquals([1, 2, 3], [1, 2]))
    }

    func testHmacSha256KnownAnswers() {
        // RFC 4231 test cases 1, 2 and 6 (key longer than the block size).
        func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(Crypto.hmacSHA256(key: [UInt8](repeating: 0x0b, count: 20), message: Array("Hi There".utf8))),
                       "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7")
        XCTAssertEqual(hex(Crypto.hmacSHA256(key: Array("Jefe".utf8), message: Array("what do ya want for nothing?".utf8))),
                       "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
        XCTAssertEqual(hex(Crypto.hmacSHA256(key: [UInt8](repeating: 0xaa, count: 131),
                                             message: Array("Test Using Larger Than Block-Size Key - Hash Key First".utf8))),
                       "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54")
        #if !canImport(CryptoKit)
        XCTAssertEqual(hex(PureSHA256.hash(Array("abc".utf8))),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex(PureSHA256.hash([])),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex(PureSHA256.hash(Array(String(repeating: "a", count: 1000).utf8))),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        #endif
    }
}
