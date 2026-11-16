import Foundation

/// Identifiers shared by the app and its Notification Service Extension. Both
/// Info.plists carry the same `AgentringAppGroup` / `AgentringKeychainGroup` values,
/// derived from `AGENTRING_BUNDLE_ID` at build time (Config/Base.xcconfig).
enum SharedConfig {
    /// Keychain service of the pairing item.
    static let keychainService = "dev.agentring.pairing"

    /// `group.<bundle id>`.
    static var appGroup: String {
        infoString("AgentringAppGroup") ?? "group.dev.agentring.app"
    }

    /// `<team id>.<bundle id>.shared`. An unsigned build expands $(AppIdentifierPrefix)
    /// to "", has no such entitlement, and `Keychain` falls back to the default group.
    static var keychainGroup: String? {
        infoString("AgentringKeychainGroup")
    }

    /// The App Group container, or the app's own Application Support directory when the
    /// build has no App Group entitlement (unsigned simulator builds).
    static var containerURL: URL {
        let fm = FileManager.default
        if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return url
        }
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func infoString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.contains("$(") { return nil }
        return value
    }
}

/// Notification categories, actions and keys shared by the app and the extension.
/// The relay sets the categories of its alert pushes (docs/ios.md).
enum NotificationIds {
    static let messageCategory = "AGENTRING_MESSAGE"
    static let missedCategory = "AGENTRING_MISSED"
    static let joinCategory = "AGENTRING_JOIN"
    static let replyFailedCategory = "AGENTRING_REPLY_FAILED"

    static let replyAction = "REPLY"
    static let joinAction = "JOIN"

    static let callIdKey = "call_id"
    static let agentNameKey = "agent_name"
    static let reasonKey = "reason"
    static let answeredAtKey = "answered_at"
    static let msgIdKey = "msg_id"

    static func joinIdentifier(_ callId: String) -> String { "join-\(callId)" }
}
