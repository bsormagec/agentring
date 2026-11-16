import Foundation
import UserNotifications
import AgentringCore

/// Runs for every alert push (`mutable-content: 1`). The relay's visible text is a
/// placeholder ("New message"); only after verifying `agentring.sig` with the pairing's
/// push secret does this put the agent's name and the real text in. A push that fails
/// verification keeps its placeholder: without Apple's filtering entitlement an
/// extension can't hide it, but it never shows text an attacker chose.
///
/// Verified messages are also written to the store shared with the app, so the thread
/// is current when the app opens.
final class NotificationService: UNNotificationServiceExtension {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private var work: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        lock.lock()
        self.contentHandler = contentHandler
        self.content = content
        lock.unlock()

        // Unreadable before the first unlock after a reboot: keep the placeholder.
        guard let pairing = PairingStore.current() else {
            deliver()
            return
        }
        let result = PushVerifier.verify(
            apnsUserInfo: request.content.userInfo,
            expectedRelayId: pairing.relayId,
            pushSecret: pairing.pushSecret
        )
        guard case .ok(let event) = result else {
            deliver()
            return
        }
        content.title = pairing.agentName
        content.threadIdentifier = pairing.relayId

        switch event {
        case .msgNew(let m):
            content.body = m.text
            content.categoryIdentifier = NotificationIds.messageCategory
            var info = content.userInfo
            info[NotificationIds.msgIdKey] = m.msgId
            content.userInfo = info
            guard m.truncated == true else {
                save(ThreadMessage(m.toMessage()), deviceId: pairing.deviceId)
                deliver()
                return
            }
            // The push carries the start of a long message: fetch the rest (about 30 s allowed).
            save(ThreadMessage(m.toMessage(), truncated: true), deviceId: pairing.deviceId)
            let api = RelayApi(baseUrl: pairing.relayUrl, deviceJwt: pairing.deviceJwt)
            let msgId = m.msgId
            let deviceId = pairing.deviceId
            let task = Task {
                if let full = try? await api.getMessage(msgId) {
                    self.save(ThreadMessage(full), deviceId: deviceId)
                    self.update { $0.body = full.text }
                }
                self.deliver()
            }
            lock.lock()
            work = task
            lock.unlock()
        case .callMissed(let missed):
            content.body = "Missed call"
            content.categoryIdentifier = NotificationIds.missedCategory
            var info = content.userInfo
            info[NotificationIds.callIdKey] = missed.callId
            content.userInfo = info
            deliver()
        default:
            deliver()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        lock.lock()
        let task = work
        lock.unlock()
        task?.cancel()
        deliver()
    }

    // MARK: -

    private func save(_ message: ThreadMessage, deviceId: String) {
        MessageStore.shared.mutate(deviceId: deviceId) { s in
            MessageStore.upsert(message, into: &s)
        }
    }

    private func update(_ change: (UNMutableNotificationContent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let content { change(content) }
    }

    /// Hands the content to the system, once.
    private func deliver() {
        lock.lock()
        let handler = contentHandler
        let content = self.content
        contentHandler = nil
        lock.unlock()
        if let handler, let content { handler(content) }
    }
}
