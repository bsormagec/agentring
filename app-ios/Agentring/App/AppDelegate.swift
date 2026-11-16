import Foundation
import UIKit
import UserNotifications
import AgentringCore

/// UIKit entry points SwiftUI doesn't cover: launch (PushKit must be set up before a
/// VoIP push is delivered to a launched app), APNs tokens, background pushes and the
/// notification center (banners, inline reply, Join).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let model = AppModel.shared
        UNUserNotificationCenter.current().delegate = self
        Notifier.registerCategories()
        model.push.start()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        AppModel.shared.push.alertTokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        AppModel.shared.push.alertTokenFailed(error)
    }

    /// Background pushes (`content-available`): `call.accept` of another phone, so this
    /// one can offer "Join". Best effort: iOS throttles these and drops them for an app
    /// the user force-quit; `active_call` in /v1/status covers the rest.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        let model = AppModel.shared
        guard let p = model.pairing ?? PairingStore.current() else { return .noData }
        guard case .ok(let event) = PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: p.relayId, pushSecret: p.pushSecret) else {
            Log.push.warning("rejected a background push")
            return .noData
        }
        switch event {
        case .callAccept(let a):
            guard a.by == "user", a.deviceId != p.deviceId, model.calls.isIdle else { return .noData }
            guard let call = try? await model.api()?.getCall(a.callId) else { return .failed }
            model.calls.offerJoin(call)
            if let offer = model.calls.joinOffer, offer.info.callId == call.callId, !model.isForeground {
                Notifier.showJoin(offer)
            }
            return .newData
        case .callEnd, .callMissed:
            model.calls.onCallEvent(event)
            return .newData
        case .msgNew, .msgRead:
            model.apply(event, advanceSeq: false, deviceId: p.deviceId)
            return .newData
        default:
            return .noData
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let category = notification.request.content.categoryIdentifier
        return await MainActor.run {
            let model = AppModel.shared
            switch category {
            case NotificationIds.messageCategory:
                // The extension already saved it: show it in the thread.
                model.reloadMessages()
                if model.messagesVisible {
                    Task { await model.markAgentMessagesRead() }
                    return []
                }
                return [.banner, .list, .sound]
            case NotificationIds.joinCategory:
                // The app shows its own Join banner in the foreground.
                return []
            default:
                return [.banner, .list, .sound]
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let action = response.actionIdentifier
        let category = content.categoryIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let fields = Self.agentringFields(content.userInfo)
        let callId = content.userInfo[NotificationIds.callIdKey] as? String
        let agentName = content.userInfo[NotificationIds.agentNameKey] as? String
        let reason = content.userInfo[NotificationIds.reasonKey] as? String
        let answeredAt = (content.userInfo[NotificationIds.answeredAtKey] as? NSNumber)?.int64Value
        await handleResponse(
            action: action, category: category, typed: typed, fields: fields,
            callId: callId, agentName: agentName, reason: reason, answeredAt: answeredAt
        )
    }

    @MainActor
    private func handleResponse(
        action: String, category: String, typed: String?, fields: [String: String]?,
        callId: String?, agentName: String?, reason: String?, answeredAt: Int64?
    ) async {
        let model = AppModel.shared
        switch category {
        case NotificationIds.messageCategory:
            if action == NotificationIds.replyAction, let text = typed {
                // Reply to the message the notification showed, if it verifies.
                var replyTo: String?
                if let fields, let p = model.pairing,
                   case .ok(.msgNew(let m)) = PushVerifier.verify(fields, expectedRelayId: p.relayId, pushSecret: p.pushSecret) {
                    replyTo = m.msgId
                }
                await model.sendReply(text, replyTo: replyTo)
            } else if action == UNNotificationDefaultActionIdentifier {
                model.selectedTab = .messages
            }
        case NotificationIds.joinCategory:
            guard let callId, action == NotificationIds.joinAction || action == UNNotificationDefaultActionIdentifier else { return }
            model.selectedTab = .home
            guard action == NotificationIds.joinAction else { return }
            let info = CallInfo(callId: callId, agentName: agentName ?? model.pairing?.agentName ?? "agent",
                                reason: reason ?? "", urgent: false, expiresAt: 0)
            await model.calls.join(JoinOffer(info: info, answeredAt: answeredAt))
        default:
            if action == UNNotificationDefaultActionIdentifier { model.selectedTab = .home }
        }
    }

    /// The signed fields of `userInfo["agentring"]` (v, relay_id, event, sig).
    private nonisolated static func agentringFields(_ userInfo: [AnyHashable: Any]) -> [String: String]? {
        guard let raw = userInfo["agentring"] as? [String: Any] else { return nil }
        var out: [String: String] = [:]
        for (k, v) in raw { if let s = v as? String { out[k] = s } }
        return out.isEmpty ? nil : out
    }
}
