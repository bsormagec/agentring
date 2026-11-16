import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Client for the push gateway (protocol/push-gateway.openapi.yaml), which lets a
/// self-hosted relay push to the App Store build. The app registers its APNs tokens
/// there and hands the returned opaque handle to its relay
/// (`ApnsTokens(gatewayHandle:)` in `pair` or `updatePushTokens`).
public enum PushGatewayClient {
    private struct RegisterBody: Encodable {
        let voipToken: String?
        let alertToken: String?
        let environment: String
        let topic: String

        enum CodingKeys: String, CodingKey {
            case voipToken = "voip_token"
            case alertToken = "alert_token"
            case environment
            case topic
        }
    }

    private struct RegisterResponse: Decodable {
        let handle: String
    }

    /// `POST {gatewayUrl}/v1/register` → handle. `tokens.environment` and `tokens.topic`
    /// are required; `gatewayHandle` is ignored. The gateway URL must be https:// unless
    /// it is on a private network (same rule as the relay URL). Throws `CoreError` for
    /// bad input and `RelayError` for the gateway's HTTP errors.
    public static func register(gatewayUrl: String, tokens: ApnsTokens, session: URLSession = .shared) async throws -> String {
        guard let environment = tokens.environment, let topic = tokens.topic else {
            throw CoreError("The APNs environment and topic are needed to register with the push gateway")
        }
        guard tokens.voipToken != nil || tokens.alertToken != nil else {
            throw CoreError("No APNs token to register with the push gateway")
        }
        guard let (scheme, host) = RelayUrlPolicy.schemeAndHost(gatewayUrl),
              scheme == "https" || (scheme == "http" && RelayUrlPolicy.isPrivateHost(host)),
              let url = URL(string: RelayApi.trimSlash(gatewayUrl) + "/v1/register")
        else {
            throw CoreError("The push gateway must use https://")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue(RelayApi.userAgent, forHTTPHeaderField: "User-Agent")
        let body = RegisterBody(voipToken: tokens.voipToken, alertToken: tokens.alertToken, environment: environment, topic: topic)
        let data = try await HTTP.send(req, body: try JSONEncoder().encode(body), session: session)
        return try JSONDecoder().decode(RegisterResponse.self, from: data).handle
    }
}
