import Foundation
import UserNotifications

/// Local notifications and the notification categories.
@MainActor
enum Notifier {
    static func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: NotificationIds.replyAction,
            title: Strings.reply,
            options: [],
            textInputButtonTitle: Strings.send,
            textInputPlaceholder: "Reply"
        )
        let join = UNNotificationAction(identifier: NotificationIds.joinAction, title: Strings.join, options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: NotificationIds.messageCategory, actions: [reply], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationIds.missedCategory, actions: [], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationIds.joinCategory, actions: [join], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: NotificationIds.replyFailedCategory, actions: [], intentIdentifiers: [], options: []),
        ])
    }

    /// Missed call. The identifier is the call id, the same as the relay's
    /// `apns-collapse-id` on its missed-call alert, so the two never show twice.
    static func showMissed(_ info: CallInfo) {
        let content = UNMutableNotificationContent()
        content.title = info.agentName
        content.body = info.reason.isEmpty ? Strings.callMissed : "\(Strings.callMissed): \(info.reason)"
        content.sound = .default
        content.categoryIdentifier = NotificationIds.missedCategory
        content.userInfo = [NotificationIds.callIdKey: info.callId]
        if let relayId = AppModel.shared.pairing?.relayId { content.threadIdentifier = relayId }
        if info.urgent { content.interruptionLevel = .timeSensitive }
        add(UNNotificationRequest(identifier: info.callId, content: content, trigger: nil))
    }

    /// "Call in progress with <agent> · Join", for a group call this phone isn't on.
    static func showJoin(_ offer: JoinOffer) {
        let info = offer.info
        let content = UNMutableNotificationContent()
        content.title = Strings.inProgressWith(info.agentName)
        content.body = info.reason.isEmpty ? Strings.joinHint : info.reason
        content.categoryIdentifier = NotificationIds.joinCategory
        var userInfo: [String: Any] = [
            NotificationIds.callIdKey: info.callId,
            NotificationIds.agentNameKey: info.agentName,
            NotificationIds.reasonKey: info.reason,
        ]
        if let answeredAt = offer.answeredAt { userInfo[NotificationIds.answeredAtKey] = NSNumber(value: answeredAt) }
        content.userInfo = userInfo
        add(UNNotificationRequest(identifier: NotificationIds.joinIdentifier(info.callId), content: content, trigger: nil))
    }

    static func cancelJoin(_ callId: String) {
        let id = NotificationIds.joinIdentifier(callId)
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    static func showReplyFailed(text: String, why: String) {
        let content = UNMutableNotificationContent()
        content.title = Strings.replyFailedTitle
        content.body = "\(text) — \(why)"
        content.categoryIdentifier = NotificationIds.replyFailedCategory
        add(UNNotificationRequest(identifier: "reply-failed", content: content, trigger: nil))
    }

    /// Removes the agent's message notifications (the thread was read).
    static func removeDeliveredMessages() {
        Task {
            let center = UNUserNotificationCenter.current()
            let ids = await center.deliveredNotifications()
                .filter { $0.request.content.categoryIdentifier == NotificationIds.messageCategory }
                .map { $0.request.identifier }
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    static func removeAll() {
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    private static func add(_ request: UNNotificationRequest) {
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.push.error("notification failed: \(Strings.describe(error), privacy: .public)")
            }
        }
    }
}
