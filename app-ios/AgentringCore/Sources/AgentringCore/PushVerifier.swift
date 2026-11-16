import Foundation

/// Verifies push payloads: only events signed by the paired relay are accepted.
/// `sig = base64url(HMAC-SHA256(base64url_decode(push_secret), utf8(event)))`.
///
/// FCM carries the signed fields as the data map; APNs carries the same object under
/// the `agentring` key of the payload, next to `aps` (`ApnsPayload` in relay.openapi.yaml).
public enum PushVerifier {
    public enum Result: Sendable, Equatable {
        case ok(Event)
        case rejected(String)
    }

    /// base64url without padding. An undecodable secret signs with an empty key, which
    /// `verify` never accepts (it rejects the secret first).
    public static func sign(pushSecret: String, eventJson: String) -> String {
        let key = Crypto.base64UrlDecode(pushSecret) ?? []
        return Crypto.base64UrlEncode(Crypto.hmacSHA256(key: key, message: Array(eventJson.utf8)))
    }

    public static func verify(_ data: [String: String], expectedRelayId: String, pushSecret: String) -> Result {
        guard data["v"] == "1" else { return .rejected("unsupported payload version \(data["v"] ?? "null")") }
        guard data["relay_id"] == expectedRelayId else { return .rejected("payload from a different relay") }
        guard let eventJson = data["event"] else { return .rejected("missing event") }
        guard let sig = data["sig"] else { return .rejected("missing signature") }
        guard Crypto.base64UrlDecode(pushSecret) != nil else { return .rejected("invalid push secret") }
        let expected = sign(pushSecret: pushSecret, eventJson: eventJson)
        guard Crypto.constantTimeEquals(Array(expected.utf8), Array(sig.utf8)) else { return .rejected("bad signature") }
        do {
            return .ok(try Event.parse(eventJson))
        } catch {
            return .rejected("malformed event: \(error.localizedDescription)")
        }
    }

    /// Verifies an APNs payload (`userInfo` of a VoIP push or a notification):
    /// `userInfo["agentring"]` holds `v`, `relay_id`, `event` and `sig` as strings.
    public static func verify(apnsUserInfo: [AnyHashable: Any], expectedRelayId: String, pushSecret: String) -> Result {
        guard let fields = agentringFields(apnsUserInfo) else { return .rejected("missing agentring payload") }
        return verify(fields, expectedRelayId: expectedRelayId, pushSecret: pushSecret)
    }

    /// Parses `userInfo["agentring"]["event"]` WITHOUT verifying it. Only for what must
    /// happen before verification (reporting a VoIP push to CallKit at once); verify
    /// before trusting anything in it.
    public static func peekEvent(apnsUserInfo: [AnyHashable: Any]) -> Event? {
        guard let event = agentringFields(apnsUserInfo)?["event"] else { return nil }
        return try? Event.parse(event)
    }

    /// The string fields of `userInfo["agentring"]`; nil when it is missing or not an object.
    static func agentringFields(_ userInfo: [AnyHashable: Any]) -> [String: String]? {
        let raw = userInfo[AnyHashable("agentring")]
        var out: [String: String] = [:]
        if let dict = raw as? [String: Any] {
            for (k, v) in dict { if let s = v as? String { out[k] = s } }
        } else if let dict = raw as? [AnyHashable: Any] {
            for (k, v) in dict {
                if let key = k.base as? String, let s = v as? String { out[key] = s }
            }
        } else {
            return nil
        }
        return out
    }
}
