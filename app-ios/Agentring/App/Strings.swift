import Foundation

/// User-facing texts built in code (mirrors app-android's strings.xml). SwiftUI views
/// use string literals directly.
enum Strings {
    static let callIncoming = "Incoming call"
    static let callConnecting = "Connecting…"
    static let callReconnecting = "Reconnecting…"
    static func calling(_ agent: String) -> String { "Calling \(agent)…" }
    static let callEnded = "Call ended"
    static let callEndedByAgent = "The agent hung up"
    static let callEndedQuota = "Call ended: this month's call minutes are used up"
    static let callDeclined = "Call declined"
    static let callMissed = "Missed call"
    static func missedFrom(_ agent: String) -> String { "Missed call from \(agent)" }
    static let callUnavailable = "This call is no longer available"
    static let callFailed = "Couldn't connect the call"
    static func inProgressWith(_ agent: String) -> String { "Call in progress with \(agent)" }
    static let joinHint = "Join the call"
    static let join = "Join"

    static let agentOffline = "The agent is offline"
    static let agentBusy = "Another call is in progress"
    static let agentQuota = "This month's call minutes are used up"
    static let callsUnavailable = "Calls are not set up on your relay (LiveKit)"
    static let agentDeclined = "The agent declined the call"
    static let agentNoAnswer = "The agent didn't answer"
    static let needsRelay = "Not connected to your relay"
    static let inCall = "You are on a call"

    static let reply = "Reply"
    static let send = "Send"
    static let replyFailedTitle = "Reply not sent"
    static let messageQuota = "Today's message limit is reached"
    static func notSent(_ why: String) -> String { "Not sent: \(why)" }
    static let newMessage = "New message"

    /// A short, user-facing description of an error from the relay or the network.
    static func describe(_ error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription, !d.isEmpty { return d }
        return (error as NSError).localizedDescription
    }
}
