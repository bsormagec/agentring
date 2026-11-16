import Foundation

/// Relay events (WebSocket frames and the `event` of push payloads). Unknown types
/// decode to `.unknown` so old apps keep working when the relay adds events.
public enum Event: Sendable, Equatable {
    case callInvite(CallInvite)
    case callRinging(CallRinging)
    /// `call.accept`
    case callAccept(CallAnswer)
    /// `call.decline`
    case callDecline(CallAnswer)
    case callEnd(CallEnd)
    case callMissed(CallMissed)
    case msgNew(MsgNew)
    case msgRead(MsgRead)
    case agentPresence(AgentPresence)
    case wsHello(WsHello)
    case unknown(type: String, id: String, ts: Int64, seq: Int64?)

    public var type: String {
        switch self {
        case .callInvite(let e): return e.type
        case .callRinging(let e): return e.type
        case .callAccept(let e), .callDecline(let e): return e.type
        case .callEnd(let e): return e.type
        case .callMissed(let e): return e.type
        case .msgNew(let e): return e.type
        case .msgRead(let e): return e.type
        case .agentPresence(let e): return e.type
        case .wsHello(let e): return e.type
        case .unknown(let type, _, _, _): return type
        }
    }

    public var id: String {
        switch self {
        case .callInvite(let e): return e.id
        case .callRinging(let e): return e.id
        case .callAccept(let e), .callDecline(let e): return e.id
        case .callEnd(let e): return e.id
        case .callMissed(let e): return e.id
        case .msgNew(let e): return e.id
        case .msgRead(let e): return e.id
        case .agentPresence(let e): return e.id
        case .wsHello(let e): return e.id
        case .unknown(_, let id, _, _): return id
        }
    }

    public var ts: Int64 {
        switch self {
        case .callInvite(let e): return e.ts
        case .callRinging(let e): return e.ts
        case .callAccept(let e), .callDecline(let e): return e.ts
        case .callEnd(let e): return e.ts
        case .callMissed(let e): return e.ts
        case .msgNew(let e): return e.ts
        case .msgRead(let e): return e.ts
        case .agentPresence(let e): return e.ts
        case .wsHello(let e): return e.ts
        case .unknown(_, _, let ts, _): return ts
        }
    }

    /// The position in the relay's event log; nil for ephemeral events (`ws.hello`, `agent.presence`).
    public var seq: Int64? {
        switch self {
        case .callInvite(let e): return e.seq
        case .callRinging(let e): return e.seq
        case .callAccept(let e), .callDecline(let e): return e.seq
        case .callEnd(let e): return e.seq
        case .callMissed(let e): return e.seq
        case .msgNew(let e): return e.seq
        case .msgRead(let e): return e.seq
        case .agentPresence(let e): return e.seq
        case .wsHello(let e): return e.seq
        case .unknown(_, _, _, let seq): return seq
        }
    }

    public static func parse(_ json: String) throws -> Event {
        try parse(data: Data(json.utf8))
    }

    public static func parse(data: Data) throws -> Event {
        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw CoreError("Malformed event: \(error.localizedDescription)")
        }
        guard let type = envelope.type else { throw CoreError("event without type") }
        switch type {
        case "call.invite": return .callInvite(try decoder.decode(CallInvite.self, from: data))
        case "call.ringing": return .callRinging(try decoder.decode(CallRinging.self, from: data))
        case "call.accept": return .callAccept(try decoder.decode(CallAnswer.self, from: data))
        case "call.decline": return .callDecline(try decoder.decode(CallAnswer.self, from: data))
        case "call.end": return .callEnd(try decoder.decode(CallEnd.self, from: data))
        case "call.missed": return .callMissed(try decoder.decode(CallMissed.self, from: data))
        case "msg.new": return .msgNew(try decoder.decode(MsgNew.self, from: data))
        case "msg.read": return .msgRead(try decoder.decode(MsgRead.self, from: data))
        case "agent.presence": return .agentPresence(try decoder.decode(AgentPresence.self, from: data))
        case "ws.hello": return .wsHello(try decoder.decode(WsHello.self, from: data))
        default: return .unknown(type: type, id: envelope.id ?? "", ts: envelope.ts ?? 0, seq: envelope.seq)
        }
    }

    /// Lenient view of any event: what `.unknown` keeps.
    private struct Envelope: Decodable {
        let type: String?
        let id: String?
        let ts: Int64?
        let seq: Int64?

        enum CodingKeys: String, CodingKey { case type, id, ts, seq }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            ts = Envelope.int64(c, .ts)
            seq = Envelope.int64(c, .seq)
        }

        private static func int64(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int64? {
            if let n = try? c.decodeIfPresent(Int64.self, forKey: key) { return n }
            if let s = try? c.decodeIfPresent(String.self, forKey: key) { return Int64(s) }
            return nil
        }
    }

    // MARK: Event payloads

    public struct CallInvite: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var callId: String
        public var direction: String
        public var agentName: String
        public var reason: String
        public var priority: String
        public var expiresAt: Int64

        public init(
            type: String = "call.invite", id: String, ts: Int64, seq: Int64? = nil,
            callId: String, direction: String, agentName: String, reason: String, priority: String, expiresAt: Int64
        ) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.callId = callId
            self.direction = direction
            self.agentName = agentName
            self.reason = reason
            self.priority = priority
            self.expiresAt = expiresAt
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case callId = "call_id"
            case direction
            case agentName = "agent_name"
            case reason
            case priority
            case expiresAt = "expires_at"
        }
    }

    public struct CallRinging: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var callId: String
        public var deviceId: String

        public init(type: String = "call.ringing", id: String, ts: Int64, seq: Int64? = nil, callId: String, deviceId: String) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.callId = callId
            self.deviceId = deviceId
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case callId = "call_id"
            case deviceId = "device_id"
        }
    }

    /// `call.accept` and `call.decline` share a shape.
    public struct CallAnswer: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var callId: String
        public var by: String
        public var deviceId: String?

        public init(type: String, id: String, ts: Int64, seq: Int64? = nil, callId: String, by: String, deviceId: String? = nil) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.callId = callId
            self.by = by
            self.deviceId = deviceId
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case callId = "call_id"
            case by
            case deviceId = "device_id"
        }
    }

    public struct CallEnd: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var callId: String
        public var by: String
        public var reason: String
        public var durationMs: Int64?

        public init(
            type: String = "call.end", id: String, ts: Int64, seq: Int64? = nil,
            callId: String, by: String, reason: String, durationMs: Int64? = nil
        ) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.callId = callId
            self.by = by
            self.reason = reason
            self.durationMs = durationMs
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case callId = "call_id"
            case by
            case reason
            case durationMs = "duration_ms"
        }
    }

    public struct CallMissed: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var callId: String

        public init(type: String = "call.missed", id: String, ts: Int64, seq: Int64? = nil, callId: String) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.callId = callId
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case callId = "call_id"
        }
    }

    public struct MsgNew: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var msgId: String
        public var from: String
        public var text: String
        public var replyTo: String?
        /// The relay cut the text to fit a push payload; fetch the message for the rest.
        public var truncated: Bool?

        public init(
            type: String = "msg.new", id: String, ts: Int64, seq: Int64? = nil,
            msgId: String, from: String, text: String, replyTo: String? = nil, truncated: Bool? = nil
        ) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.msgId = msgId
            self.from = from
            self.text = text
            self.replyTo = replyTo
            self.truncated = truncated
        }

        public func toMessage() -> Message {
            Message(msgId: msgId, from: from, text: text, replyTo: replyTo, createdAt: ts)
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case msgId = "msg_id"
            case from
            case text
            case replyTo = "reply_to"
            case truncated
        }
    }

    public struct MsgRead: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var msgId: String
        public var by: String

        public init(type: String = "msg.read", id: String, ts: Int64, seq: Int64? = nil, msgId: String, by: String) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.msgId = msgId
            self.by = by
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case msgId = "msg_id"
            case by
        }
    }

    public struct AgentPresence: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var online: Bool

        public init(type: String = "agent.presence", id: String, ts: Int64, seq: Int64? = nil, online: Bool) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.online = online
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case online
        }
    }

    public struct WsHello: Codable, Equatable, Sendable {
        public var type: String
        public var id: String
        public var ts: Int64
        public var seq: Int64?
        public var relayId: String
        public var lastSeq: Int64
        public var serverTs: Int64

        public init(
            type: String = "ws.hello", id: String, ts: Int64, seq: Int64? = nil,
            relayId: String, lastSeq: Int64, serverTs: Int64
        ) {
            self.type = type
            self.id = id
            self.ts = ts
            self.seq = seq
            self.relayId = relayId
            self.lastSeq = lastSeq
            self.serverTs = serverTs
        }

        enum CodingKeys: String, CodingKey {
            case type, id, ts, seq
            case relayId = "relay_id"
            case lastSeq = "last_seq"
            case serverTs = "server_ts"
        }
    }
}

extension Event: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Re-dispatch through the typed parsers: decode each payload from the same container.
        let type = try decoder.container(keyedBy: TypeKey.self).decodeIfPresent(String.self, forKey: .type)
        guard let type else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "event without type")
        }
        switch type {
        case "call.invite": self = .callInvite(try c.decode(CallInvite.self))
        case "call.ringing": self = .callRinging(try c.decode(CallRinging.self))
        case "call.accept": self = .callAccept(try c.decode(CallAnswer.self))
        case "call.decline": self = .callDecline(try c.decode(CallAnswer.self))
        case "call.end": self = .callEnd(try c.decode(CallEnd.self))
        case "call.missed": self = .callMissed(try c.decode(CallMissed.self))
        case "msg.new": self = .msgNew(try c.decode(MsgNew.self))
        case "msg.read": self = .msgRead(try c.decode(MsgRead.self))
        case "agent.presence": self = .agentPresence(try c.decode(AgentPresence.self))
        case "ws.hello": self = .wsHello(try c.decode(WsHello.self))
        default:
            let k = try decoder.container(keyedBy: UnknownKeys.self)
            let id = (try? k.decodeIfPresent(String.self, forKey: .id)) ?? nil
            let ts = (try? k.decodeIfPresent(Int64.self, forKey: .ts)) ?? nil
            let seq = (try? k.decodeIfPresent(Int64.self, forKey: .seq)) ?? nil
            self = .unknown(type: type, id: id ?? "", ts: ts ?? 0, seq: seq)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .callInvite(let e): try e.encode(to: encoder)
        case .callRinging(let e): try e.encode(to: encoder)
        case .callAccept(let e), .callDecline(let e): try e.encode(to: encoder)
        case .callEnd(let e): try e.encode(to: encoder)
        case .callMissed(let e): try e.encode(to: encoder)
        case .msgNew(let e): try e.encode(to: encoder)
        case .msgRead(let e): try e.encode(to: encoder)
        case .agentPresence(let e): try e.encode(to: encoder)
        case .wsHello(let e): try e.encode(to: encoder)
        case .unknown(let type, let id, let ts, let seq):
            var k = encoder.container(keyedBy: UnknownKeys.self)
            try k.encode(type, forKey: .type)
            try k.encode(id, forKey: .id)
            try k.encode(ts, forKey: .ts)
            try k.encodeIfPresent(seq, forKey: .seq)
        }
    }

    private enum TypeKey: String, CodingKey { case type }
    private enum UnknownKeys: String, CodingKey { case type, id, ts, seq }
}
