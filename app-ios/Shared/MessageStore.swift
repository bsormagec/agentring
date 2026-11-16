import Foundation
import AgentringCore

/// One message of the thread, as the app stores it.
struct ThreadMessage: Codable, Equatable, Identifiable, Sendable {
    var msgId: String
    var from: String
    var text: String
    var replyTo: String?
    var clientMsgId: String?
    var createdAt: Int64
    var readAt: Int64?
    /// The text came from a push and was cut (`truncated: true`); the full text is on the relay.
    var truncated: Bool

    var id: String { msgId }
    var fromAgent: Bool { from == Message.fromAgentValue }

    init(_ m: Message, truncated: Bool = false) {
        msgId = m.msgId
        from = m.from
        text = m.text
        replyTo = m.replyTo
        clientMsgId = m.clientMsgId
        createdAt = m.createdAt
        readAt = m.readAt
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case msgId = "msg_id"
        case from
        case text
        case replyTo = "reply_to"
        case clientMsgId = "client_msg_id"
        case createdAt = "created_at"
        case readAt = "read_at"
        case truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        msgId = try c.decode(String.self, forKey: .msgId)
        from = try c.decode(String.self, forKey: .from)
        text = try c.decode(String.self, forKey: .text)
        replyTo = try c.decodeIfPresent(String.self, forKey: .replyTo)
        clientMsgId = try c.decodeIfPresent(String.self, forKey: .clientMsgId)
        createdAt = try c.decode(Int64.self, forKey: .createdAt)
        readAt = try c.decodeIfPresent(Int64.self, forKey: .readAt)
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

/// The conversation with the agent plus the WebSocket resume point, in one JSON file
/// in the App Group container. The relay is the source of truth; this is a cache the
/// app and the Notification Service Extension both write (coordinated with
/// `NSFileCoordinator`, so the two processes don't overwrite each other).
///
/// The file belongs to one pairing (`device_id`): writes for another device are
/// dropped, so a late answer for an old pairing can't reach the new one.
final class MessageStore: @unchecked Sendable {
    struct Snapshot: Codable, Equatable {
        var deviceId: String?
        /// Highest relay event `seq` applied from the WebSocket stream.
        var lastSeq: Int64
        var messages: [ThreadMessage]

        static let empty = Snapshot(deviceId: nil, lastSeq: 0, messages: [])

        enum CodingKeys: String, CodingKey {
            case deviceId = "device_id"
            case lastSeq = "last_seq"
            case messages
        }
    }

    static let shared = MessageStore()
    static let maxCached = 500

    private let url: URL
    private let lock = NSLock()

    init(url: URL = SharedConfig.containerURL.appendingPathComponent("messages.json")) {
        self.url = url
    }

    /// Current contents; empty when the file is missing or can't be read.
    func read() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        var snapshot = Snapshot.empty
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            if case .ok(let s) = load(u) { snapshot = s }
        }
        return snapshot
    }

    /// Read-modify-write for `deviceId`'s thread. Returns the new snapshot, or nil when
    /// the store belongs to another pairing or can't be read (e.g. before the first
    /// unlock: data protection keeps the file closed, and it must not be overwritten).
    @discardableResult
    func mutate(deviceId: String, _ block: (inout Snapshot) -> Void) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        var result: Snapshot?
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forMerging, error: &coordError) { u in
            var snapshot: Snapshot
            switch load(u) {
            case .ok(let s): snapshot = s
            case .missing: snapshot = Snapshot(deviceId: deviceId, lastSeq: 0, messages: [])
            case .unreadable: return
            }
            guard snapshot.deviceId == deviceId else { return }
            block(&snapshot)
            if snapshot.messages.count > Self.maxCached {
                snapshot.messages = Array(snapshot.messages.suffix(Self.maxCached))
            }
            if save(snapshot, to: u) { result = snapshot }
        }
        return result
    }

    /// Starts an empty thread for `deviceId` (nil = no pairing).
    func reset(deviceId: String?) {
        lock.lock()
        defer { lock.unlock() }
        var coordError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            _ = save(Snapshot(deviceId: deviceId, lastSeq: 0, messages: []), to: u)
        }
    }

    // MARK: - Thread operations (pure, used inside `mutate`)

    /// Inserts or updates by msg_id. A truncated text never overwrites a full one.
    static func upsert(_ m: ThreadMessage, into s: inout Snapshot) {
        var merged = m
        if let i = s.messages.firstIndex(where: { $0.msgId == m.msgId }) {
            let existing = s.messages[i]
            if m.truncated && !existing.truncated {
                merged = existing
                merged.readAt = existing.readAt ?? m.readAt
            } else {
                merged.readAt = m.readAt ?? existing.readAt
            }
            s.messages.remove(at: i)
        }
        // msg_ids are time-ordered (ULID-like), as on Android.
        let at = s.messages.firstIndex(where: { $0.msgId > merged.msgId }) ?? s.messages.endIndex
        s.messages.insert(merged, at: at)
    }

    static func markRead(_ msgId: String, at ts: Int64, in s: inout Snapshot) {
        if let i = s.messages.firstIndex(where: { $0.msgId == msgId }), s.messages[i].readAt == nil {
            s.messages[i].readAt = ts
        }
    }

    // MARK: - File I/O

    private enum LoadResult {
        case ok(Snapshot)
        case missing
        case unreadable
    }

    private func load(_ u: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: u.path) else { return .missing }
        guard let data = try? Data(contentsOf: u) else { return .unreadable }
        // A corrupt cache is dropped: the relay has everything.
        guard let s = try? JSONDecoder().decode(Snapshot.self, from: data) else { return .missing }
        return .ok(s)
    }

    private func save(_ s: Snapshot, to u: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(s) else { return false }
        do {
            #if os(iOS)
            try data.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: u, options: [.atomic])
            #endif
            return true
        } catch {
            return false
        }
    }
}
