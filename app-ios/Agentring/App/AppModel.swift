import Foundation
import Observation
import UIKit
import UserNotifications
import AgentringCore

enum AppTab: Hashable {
    case home, messages, settings
}

/// Process-wide state and the small amount of glue between the pieces (the iOS
/// counterpart of app-android's `Graph` + `PairingStore` + `MessageRepository`).
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// The current pairing (Keychain). nil = not paired, or the Keychain is still locked.
    private(set) var pairing: Pairing?
    /// The Keychain couldn't be read yet (launched by a push before the first unlock).
    private(set) var pairingLocked = false
    /// The relay rejected our credentials; the user must pair again.
    private(set) var revoked = false
    /// Onboarding finished (the user saw the "paired" screen).
    private(set) var setupComplete: Bool
    /// The user went past the welcome / permissions screens.
    private(set) var introSeen: Bool
    private(set) var messages: [ThreadMessage] = []
    var selectedTab: AppTab = .home
    /// The thread is on screen: incoming agent messages are read at once and not notified.
    var messagesVisible = false
    private(set) var isForeground = false

    let connection = ConnectionManager()
    let push = PushRegistrar()
    let calls = CallController()

    private let store = MessageStore.shared

    private enum Keys {
        static let setupComplete = "setup_complete"
        static let introSeen = "intro_seen"
    }

    private init() {
        setupComplete = UserDefaults.standard.bool(forKey: Keys.setupComplete)
        introSeen = UserDefaults.standard.bool(forKey: Keys.introSeen)
        loadPairing()
        NotificationCenter.default.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: nil
        ) { _ in
            onMain { AppModel.shared.protectedDataAvailable() }
        }
    }

    // MARK: - Pairing

    private func loadPairing() {
        switch PairingStore.load() {
        case .found(let p):
            pairing = p
            pairingLocked = false
        case .none:
            pairing = nil
            pairingLocked = false
        case .unavailable:
            pairing = nil
            pairingLocked = true
        }
        reloadMessages()
    }

    private func protectedDataAvailable() {
        guard pairingLocked else { return }
        Log.app.info("Keychain available: loading the pairing")
        loadPairing()
        connection.reconnect()
        Task { await push.ensureRegistered() }
    }

    /// REST client for the current pairing, or nil if not paired.
    func api() -> RelayApi? {
        guard let p = pairing else { return nil }
        return RelayApi(baseUrl: p.relayUrl, deviceJwt: p.deviceJwt)
    }

    /// Redeems a scanned or pasted pairing code.
    func pair(code: String) async throws {
        let qr = try QrPayload.parse(code.trimmingCharacters(in: .whitespacesAndNewlines))
        try RelayUrlPolicy.check(qr.relayUrl)
        let request = PairRequest(
            pairingToken: qr.pairingToken,
            deviceName: AppInfo.deviceName(),
            appVersion: AppInfo.version,
            apns: push.tokensForPairing()
        )
        let res = try await RelayApi(baseUrl: qr.relayUrl).pair(request)
        let settings: PushSettings? = res.pushConfig.map { config in
            PushSettings(
                provider: config.provider,
                topic: config.apns?.topic,
                viaGateway: config.apns?.viaGateway ?? false,
                gatewayUrl: config.apns?.gatewayUrl
            )
        }
        let p = Pairing(
            relayUrl: qr.relayUrl,
            relayId: res.relayId,
            deviceId: res.deviceId,
            deviceJwt: res.deviceJwt,
            pushSecret: res.pushSecret,
            agentName: res.agentName,
            push: settings
        )
        // In this order: whatever reads the pairing after the reset is the new one.
        connection.disconnect()
        PairingStore.save(p)
        store.reset(deviceId: p.deviceId)
        pairing = p
        pairingLocked = false
        revoked = false
        messages = []
        setSetupComplete(false)
        calls.onActiveCall(nil)
        push.pairingChanged()
        connection.reconnect()
        Task { await push.ensureRegistered() }
        Log.app.info("paired with \(p.relayId, privacy: .public) as \(p.deviceId, privacy: .public)")
    }

    /// Forgets the pairing locally (the relay keeps it until `agentring devices revoke`).
    func unpair() {
        connection.disconnect()
        calls.hangUp()
        PairingStore.save(nil)
        store.reset(deviceId: nil)
        pairing = nil
        revoked = false
        messages = []
        setSetupComplete(false)
        calls.onActiveCall(nil)
        push.pairingChanged()
        Notifier.removeAll()
    }

    func markRevoked() {
        guard pairing != nil, !revoked else { return }
        Log.app.warning("the relay rejected our credentials")
        revoked = true
        connection.disconnect()
    }

    func setSetupComplete(_ done: Bool) {
        setupComplete = done
        UserDefaults.standard.set(done, forKey: Keys.setupComplete)
    }

    func setIntroSeen() {
        introSeen = true
        UserDefaults.standard.set(true, forKey: Keys.introSeen)
    }

    // MARK: - Lifecycle

    func didBecomeActive() {
        isForeground = true
        if pairingLocked { loadPairing() }
        reloadMessages()
        connection.setForeground(true)
        Task { await push.refreshNotificationSettings() }
        if messagesVisible { Task { await markAgentMessagesRead() } }
    }

    func didEnterBackground() {
        isForeground = false
        connection.setForeground(false)
    }

    // MARK: - Messages

    /// Re-reads the shared store (the Notification Service Extension writes to it too).
    func reloadMessages() {
        guard let p = pairing else {
            messages = []
            return
        }
        let snapshot = store.read()
        messages = snapshot.deviceId == p.deviceId ? snapshot.messages : []
    }

    /// The WebSocket resume point of the current pairing.
    nonisolated static func lastSeq(deviceId: String) -> Int64 {
        let snapshot = MessageStore.shared.read()
        return snapshot.deviceId == deviceId ? snapshot.lastSeq : 0
    }

    /// Applies a relay event. `advanceSeq` is false for push-delivered events.
    func apply(_ event: Event, advanceSeq: Bool, deviceId: String) {
        let seq = event.seq
        var changesThread = false
        switch event {
        case .msgNew, .msgRead: changesThread = true
        default: break
        }
        let advances = advanceSeq && seq != nil
        guard changesThread || advances else { return }
        let updated = store.mutate(deviceId: deviceId) { s in
            switch event {
            case .msgNew(let m):
                MessageStore.upsert(ThreadMessage(m.toMessage(), truncated: m.truncated == true), into: &s)
            case .msgRead(let r):
                MessageStore.markRead(r.msgId, at: r.ts, in: &s)
            default:
                break
            }
            if advanceSeq, let seq, seq > s.lastSeq { s.lastSeq = seq }
        }
        guard let updated, pairing?.deviceId == deviceId else { return }
        messages = updated.messages
        if case .msgNew(let m) = event {
            if m.truncated == true { Task { await fetchFull(m.msgId, deviceId: deviceId) } }
            if m.from == Message.fromAgentValue, messagesVisible, isForeground {
                Task { await markAgentMessagesRead() }
            }
        }
    }

    private func fetchFull(_ msgId: String, deviceId: String) async {
        guard let api = api(), let full = try? await api.getMessage(msgId) else { return }
        upsert([full], deviceId: deviceId)
    }

    private func upsert(_ list: [Message], deviceId: String) {
        guard !list.isEmpty else { return }
        let updated = store.mutate(deviceId: deviceId) { s in
            for m in list { MessageStore.upsert(ThreadMessage(m), into: &s) }
        }
        if let updated, pairing?.deviceId == deviceId { messages = updated.messages }
    }

    /// Pulls messages we don't have yet.
    func refreshMessages() async throws {
        guard let p = pairing, let api = api() else { return }
        var after = messages.last(where: { !$0.truncated })?.msgId ?? messages.last?.msgId
        while pairing?.deviceId == p.deviceId {
            let page = try await api.listMessages(after: after)
            upsert(page.messages, deviceId: p.deviceId)
            guard page.hasMore, let last = page.messages.last else { return }
            after = last.msgId
        }
    }

    /// Sends a message to the agent. Returns an error text, or nil when sent.
    func send(_ text: String, replyTo: String? = nil) async -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let p = pairing, let api = api() else { return Strings.needsRelay }
        do {
            let sent = try await api.postMessage(text: trimmed, replyTo: replyTo, clientMsgId: UUID().uuidString)
            upsert([sent], deviceId: p.deviceId)
            return nil
        } catch let e as RelayError {
            if e.isUnauthorized { markRevoked() }
            return e.code == "quota_exceeded" ? Strings.messageQuota : Strings.notSent(e.message)
        } catch {
            return Strings.notSent(Strings.describe(error))
        }
    }

    /// Sends read receipts for the agent's unread messages.
    func markAgentMessagesRead() async {
        guard let p = pairing, let api = api() else { return }
        let unread = messages.filter { $0.fromAgent && $0.readAt == nil }
        for m in unread {
            do {
                try await api.markRead(m.msgId)
            } catch {
                Log.relay.warning("markRead failed: \(Strings.describe(error), privacy: .public)")
                return
            }
            let now = nowMs()
            let updated = store.mutate(deviceId: p.deviceId) { s in MessageStore.markRead(m.msgId, at: now, in: &s) }
            if let updated, pairing?.deviceId == p.deviceId { messages = updated.messages }
        }
        Notifier.removeDeliveredMessages()
    }

    /// Inline reply from a message notification (the app runs in the background).
    func sendReply(_ text: String, replyTo: String?) async {
        if let why = await send(text, replyTo: replyTo) {
            Notifier.showReplyFailed(text: text, why: why)
            return
        }
        // Replying implies the user read what the agent said.
        await markAgentMessagesRead()
    }
}
