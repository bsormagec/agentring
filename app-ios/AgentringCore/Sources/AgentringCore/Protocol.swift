import Foundation

// Swift mirror of protocol/relay.openapi.yaml (and of the Android app's Protocol.kt).
// Kept honest by ProtocolFixturesTests, which decodes and round-trips every file in
// protocol/examples. JSON is snake_case on the wire; every type spells its keys out in
// CodingKeys. Unknown keys are ignored; optional fields decode missing or null as nil
// and are omitted when encoding nil. Times are Int64 milliseconds since the epoch.

/// A user-facing error raised by the core (bad pairing code, URL policy, ...).
public struct CoreError: Error, LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) { self.message = message }
    public init(message: String) { self.message = message }

    public var errorDescription: String? { message }
}

// MARK: - Pairing

/// The content of the pairing QR code (or the pasted pairing code).
public struct QrPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var relayUrl: String
    public var pairingToken: String

    public init(v: Int, relayUrl: String, pairingToken: String) {
        self.v = v
        self.relayUrl = relayUrl
        self.pairingToken = pairingToken
    }

    enum CodingKeys: String, CodingKey {
        case v
        case relayUrl = "relay_url"
        case pairingToken = "pairing_token"
    }

    /// Parses the QR / pasted pairing code. Throws `CoreError` with a user-facing reason.
    public static func parse(_ raw: String) throws -> QrPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let p: QrPayload
        do {
            p = try JSONDecoder().decode(QrPayload.self, from: Data(trimmed.utf8))
        } catch {
            throw CoreError("This is not an agentring pairing code")
        }
        guard p.v == 1 else { throw CoreError("Unsupported pairing code version \(p.v); update the app") }
        guard p.pairingToken.hasPrefix("pt_") else { throw CoreError("Invalid pairing token") }
        try RelayUrlPolicy.check(p.relayUrl)
        return p
    }
}

/// A device's APNs registration: direct tokens (hex strings from iOS) or a push
/// gateway handle. All fields are optional; nil fields are not sent.
public struct ApnsTokens: Codable, Equatable, Sendable {
    public var voipToken: String?
    public var alertToken: String?
    /// "sandbox" (debug builds) or "production" (TestFlight / App Store).
    public var environment: String?
    /// The app's bundle id.
    public var topic: String?
    public var gatewayHandle: String?

    public init(
        voipToken: String? = nil,
        alertToken: String? = nil,
        environment: String? = nil,
        topic: String? = nil,
        gatewayHandle: String? = nil
    ) {
        self.voipToken = voipToken
        self.alertToken = alertToken
        self.environment = environment
        self.topic = topic
        self.gatewayHandle = gatewayHandle
    }

    enum CodingKeys: String, CodingKey {
        case voipToken = "voip_token"
        case alertToken = "alert_token"
        case environment
        case topic
        case gatewayHandle = "gateway_handle"
    }
}

public struct PairRequest: Codable, Equatable, Sendable {
    public var pairingToken: String
    public var deviceName: String
    public var platform: String
    public var appVersion: String?
    public var apns: ApnsTokens?

    public init(
        pairingToken: String,
        deviceName: String,
        platform: String = "ios",
        appVersion: String? = nil,
        apns: ApnsTokens? = nil
    ) {
        self.pairingToken = pairingToken
        self.deviceName = deviceName
        self.platform = platform
        self.appVersion = appVersion
        self.apns = apns
    }

    enum CodingKeys: String, CodingKey {
        case pairingToken = "pairing_token"
        case deviceName = "device_name"
        case platform
        case appVersion = "app_version"
        case apns
    }
}

public struct ApnsPushConfig: Codable, Equatable, Sendable {
    /// The bundle id the relay's APNs key can reach; compare it with the app's own.
    public var topic: String
    /// The relay pushes through a push gateway: register there first and send the handle.
    public var viaGateway: Bool
    public var gatewayUrl: String?

    public init(topic: String, viaGateway: Bool, gatewayUrl: String? = nil) {
        self.topic = topic
        self.viaGateway = viaGateway
        self.gatewayUrl = gatewayUrl
    }

    enum CodingKeys: String, CodingKey {
        case topic
        case viaGateway = "via_gateway"
        case gatewayUrl = "gateway_url"
    }
}

/// How the app should register for push. The Android-only `fcm` object is ignored.
public struct PushConfig: Codable, Equatable, Sendable {
    public var provider: String
    public var apns: ApnsPushConfig?

    public init(provider: String, apns: ApnsPushConfig? = nil) {
        self.provider = provider
        self.apns = apns
    }

    enum CodingKeys: String, CodingKey {
        case provider
        case apns
    }
}

public struct PairResponse: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceJwt: String
    /// base64url, 32 bytes: the HMAC key for push payloads.
    public var pushSecret: String
    public var relayId: String
    public var agentName: String
    /// nil when the relay has no push configured for iOS.
    public var pushConfig: PushConfig?

    public init(
        deviceId: String,
        deviceJwt: String,
        pushSecret: String,
        relayId: String,
        agentName: String,
        pushConfig: PushConfig? = nil
    ) {
        self.deviceId = deviceId
        self.deviceJwt = deviceJwt
        self.pushSecret = pushSecret
        self.relayId = relayId
        self.agentName = agentName
        self.pushConfig = pushConfig
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceJwt = "device_jwt"
        case pushSecret = "push_secret"
        case relayId = "relay_id"
        case agentName = "agent_name"
        case pushConfig = "push_config"
    }
}

// MARK: - Messages

public struct Message: Codable, Equatable, Sendable {
    public static let fromAgentValue = "agent"
    public static let fromUserValue = "user"

    public var msgId: String
    public var from: String
    public var text: String
    public var replyTo: String?
    public var clientMsgId: String?
    public var deviceId: String?
    public var createdAt: Int64
    public var readAt: Int64?

    public var fromAgent: Bool { from == Message.fromAgentValue }

    public init(
        msgId: String,
        from: String,
        text: String,
        replyTo: String? = nil,
        clientMsgId: String? = nil,
        deviceId: String? = nil,
        createdAt: Int64,
        readAt: Int64? = nil
    ) {
        self.msgId = msgId
        self.from = from
        self.text = text
        self.replyTo = replyTo
        self.clientMsgId = clientMsgId
        self.deviceId = deviceId
        self.createdAt = createdAt
        self.readAt = readAt
    }

    enum CodingKeys: String, CodingKey {
        case msgId = "msg_id"
        case from
        case text
        case replyTo = "reply_to"
        case clientMsgId = "client_msg_id"
        case deviceId = "device_id"
        case createdAt = "created_at"
        case readAt = "read_at"
    }
}

public struct MessagePage: Codable, Equatable, Sendable {
    public var messages: [Message]
    public var hasMore: Bool

    public init(messages: [Message], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }

    enum CodingKeys: String, CodingKey {
        case messages
        case hasMore = "has_more"
    }
}

// MARK: - System

public struct Status: Codable, Equatable, Sendable {
    public var relayId: String
    public var version: String
    public var agentName: String
    public var agentOnline: Bool
    /// Deprecated on the relay; prefer `pushProviders`.
    public var pushProvider: String?
    public var pushProviders: [String]?
    /// The call currently ringing or active, if any.
    public var activeCall: Call?

    public init(
        relayId: String,
        version: String,
        agentName: String,
        agentOnline: Bool,
        pushProvider: String? = nil,
        pushProviders: [String]? = nil,
        activeCall: Call? = nil
    ) {
        self.relayId = relayId
        self.version = version
        self.agentName = agentName
        self.agentOnline = agentOnline
        self.pushProvider = pushProvider
        self.pushProviders = pushProviders
        self.activeCall = activeCall
    }

    enum CodingKeys: String, CodingKey {
        case relayId = "relay_id"
        case version
        case agentName = "agent_name"
        case agentOnline = "agent_online"
        case pushProvider = "push_provider"
        case pushProviders = "push_providers"
        case activeCall = "active_call"
    }
}

// MARK: - Calls

public struct Call: Codable, Equatable, Sendable {
    public var callId: String
    /// "agent_to_user" or "user_to_agent".
    public var direction: String
    /// "ringing", "active", "ended", "declined", "missed", "canceled", ...
    public var state: String
    public var reason: String?
    /// "normal" or "urgent".
    public var priority: String
    public var agentName: String
    public var createdAt: Int64
    public var answeredAt: Int64?
    public var endedAt: Int64?
    public var endedBy: String?
    public var endReason: String?
    public var durationMs: Int64?
    public var deviceId: String?

    public var isRinging: Bool { state == "ringing" }
    public var isActive: Bool { state == "active" }
    /// A group call from the agent that is in progress: a phone not on it may join.
    public var isJoinable: Bool { isActive && direction == "agent_to_user" }

    public init(
        callId: String,
        direction: String,
        state: String,
        reason: String? = nil,
        priority: String,
        agentName: String,
        createdAt: Int64,
        answeredAt: Int64? = nil,
        endedAt: Int64? = nil,
        endedBy: String? = nil,
        endReason: String? = nil,
        durationMs: Int64? = nil,
        deviceId: String? = nil
    ) {
        self.callId = callId
        self.direction = direction
        self.state = state
        self.reason = reason
        self.priority = priority
        self.agentName = agentName
        self.createdAt = createdAt
        self.answeredAt = answeredAt
        self.endedAt = endedAt
        self.endedBy = endedBy
        self.endReason = endReason
        self.durationMs = durationMs
        self.deviceId = deviceId
    }

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case direction
        case state
        case reason
        case priority
        case agentName = "agent_name"
        case createdAt = "created_at"
        case answeredAt = "answered_at"
        case endedAt = "ended_at"
        case endedBy = "ended_by"
        case endReason = "end_reason"
        case durationMs = "duration_ms"
        case deviceId = "device_id"
    }
}

public struct JoinInfo: Codable, Equatable, Sendable {
    public var livekitUrl: String
    public var livekitToken: String
    public var room: String
    public var identity: String
    public var expiresAt: Int64

    public init(livekitUrl: String, livekitToken: String, room: String, identity: String, expiresAt: Int64) {
        self.livekitUrl = livekitUrl
        self.livekitToken = livekitToken
        self.room = room
        self.identity = identity
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case livekitUrl = "livekit_url"
        case livekitToken = "livekit_token"
        case room
        case identity
        case expiresAt = "expires_at"
    }
}

public struct CallWithJoin: Codable, Equatable, Sendable {
    public var call: Call
    public var join: JoinInfo

    public init(call: Call, join: JoinInfo) {
        self.call = call
        self.join = join
    }

    enum CodingKeys: String, CodingKey {
        case call
        case join
    }
}

// MARK: - Errors

/// An HTTP error from the relay (or the push gateway), parsed from `{"error":{"code","message"}}`.
public struct RelayError: Error, LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// Credentials are no longer valid (device revoked or relay reset): the app must re-pair.
    public var isUnauthorized: Bool { status == 401 }

    public var errorDescription: String? { message }
}

struct ApiErrorBody: Decodable {
    struct Detail: Decodable {
        let code: String
        let message: String
    }

    let error: Detail
}
