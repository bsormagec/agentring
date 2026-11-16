import XCTest
@testable import AgentringCore

final class RelayUrlPolicyTests: XCTestCase {
    func testQrPayloadParsingAndUrlPolicy() throws {
        let p = try QrPayload.parse(#"  {"v":1,"relay_url":"https://relay.example.com","pairing_token":"pt_abc"} "#)
        XCTAssertEqual(p.relayUrl, "https://relay.example.com")
        XCTAssertEqual(p.pairingToken, "pt_abc")
        XCTAssertEqual(p.v, 1)
        XCTAssertNoThrow(try QrPayload.parse(#"{"v":1,"relay_url":"http://192.168.1.20:8080","pairing_token":"pt_abc"}"#))
        XCTAssertNoThrow(try QrPayload.parse(#"{"v":1,"relay_url":"http://10.0.2.2:8080","pairing_token":"pt_abc"}"#))
        XCTAssertNoThrow(try QrPayload.parse("\n{\"v\":1,\"relay_url\":\"https://x\",\"pairing_token\":\"pt_abc\",\"extra\":1}\n"))

        let cases: [(String, String)] = [
            ("hello", "This is not an agentring pairing code"),
            (#"{"v":"1","relay_url":"https://x","pairing_token":"pt_abc"}"#, "This is not an agentring pairing code"),
            (#"{"v":1,"relay_url":"https://x"}"#, "This is not an agentring pairing code"),
            (#"{"v":2,"relay_url":"https://x","pairing_token":"pt_abc"}"#, "Unsupported pairing code version 2; update the app"),
            (#"{"v":1,"relay_url":"http://relay.example.com","pairing_token":"pt_abc"}"#,
             "The relay must use https:// (http is only allowed on a local network)"),
            (#"{"v":1,"relay_url":"ftp://x","pairing_token":"pt_abc"}"#, "The relay URL must start with https://"),
            (#"{"v":1,"relay_url":"https://x","pairing_token":"nope"}"#, "Invalid pairing token"),
            (#"{"v":1,"relay_url":"relay.example.com","pairing_token":"pt_abc"}"#, "Invalid relay URL"),
        ]
        for (raw, message) in cases {
            XCTAssertThrowsError(try QrPayload.parse(raw), raw) { error in
                XCTAssertEqual(error as? CoreError, CoreError(message), raw)
                XCTAssertEqual(error.localizedDescription, message, raw)
            }
        }
    }

    func testPrivateHosts() {
        for host in [
            "localhost", "LOCALHOST", "mac-mini.local", "::1", "[::1]", "10.0.2.2", "10.255.255.255", "127.0.0.1",
            "192.168.1.20", "172.16.0.1", "172.20.0.1", "172.31.255.255", "100.64.0.1", "100.127.255.255",
        ] {
            XCTAssertTrue(RelayUrlPolicy.isPrivateHost(host), host)
        }
        for host in [
            "8.8.8.8", "172.32.0.1", "172.15.0.1", "192.169.1.1", "100.63.0.1", "100.128.0.1", "11.0.0.1",
            "relay.example.com", "localhost.example.com", "10.0.0", "10.0.0.1.2", "10.0.0.256", "10.0.0.x", "",
            "fd00::1", "[fe80::1]", "::", "::ffff:10.0.0.1", "2001:db8::1",
        ] {
            XCTAssertFalse(RelayUrlPolicy.isPrivateHost(host), host)
        }
    }

    func testRelayUrls() {
        for ok in [
            "https://relay.example.com", "https://relay.example.com:8443/base", "https://8.8.8.8",
            "http://localhost:8080", "http://127.0.0.1:8080", "http://[::1]:8080", "http://nas.local",
            "http://100.101.102.103:8080", "https://[2001:db8::1]/",
        ] {
            XCTAssertNoThrow(try RelayUrlPolicy.check(ok), ok)
        }
        for bad in [
            "http://relay.example.com", "http://8.8.8.8", "http://[fd00::1]:8080", "http://[2001:db8::1]",
            "ws://localhost", "ftp://x", "not a url", "", "https://", "relay.example.com",
        ] {
            XCTAssertThrowsError(try RelayUrlPolicy.check(bad), bad) { XCTAssertTrue($0 is CoreError, bad) }
        }
    }

    func testLiveKitUrlMustBeWssOutsideAPrivateNetwork() {
        for ok in [
            "wss://relay.example.com", "ws://localhost:7880", "ws://192.168.1.10:7880", "https://relay.example.com",
            "http://10.0.0.5:7880", "ws://[::1]:7880",
        ] {
            XCTAssertNoThrow(try RelayUrlPolicy.checkLiveKit(ok), ok)
        }
        for bad in ["ws://relay.example.com", "http://8.8.8.8", "ftp://x", "not a url", "ws://[fd00::1]:7880"] {
            XCTAssertThrowsError(try RelayUrlPolicy.checkLiveKit(bad), bad) { XCTAssertTrue($0 is CoreError, bad) }
        }
        XCTAssertThrowsError(try RelayUrlPolicy.checkLiveKit("ws://relay.example.com")) {
            XCTAssertEqual($0 as? CoreError, CoreError("LiveKit must use wss:// (ws is only allowed on a local network)"))
        }
    }
}
