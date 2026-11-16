import Foundation
import Observation
import PushKit
import UIKit
import UserNotifications
import AgentringCore

enum PushState: Equatable {
    /// The relay has no push for iOS (`push_config` null): events only arrive while the app is open.
    case notConfigured
    /// The relay pushes to another bundle id: its APNs key can't wake this app.
    case topicMismatch(String)
    /// Waiting for iOS to hand out the VoIP and alert tokens.
    case waitingForTokens
    case registering
    case registered
    case error(String)
}

/// Gets the PushKit (VoIP) and APNs alert tokens and keeps the relay's copy current:
/// directly (`POST /v1/device/push-tokens`) or, when the relay pushes through a push
/// gateway, by registering with the gateway and giving the relay only the handle.
///
/// The relay replaces the whole APNs registration on every upload, so both tokens go
/// together with `environment` and `topic`, once per app start and whenever a token
/// changes (the relay drops tokens APNs reports dead).
@MainActor
@Observable
final class PushRegistrar {
    private(set) var state: PushState = .notConfigured
    private(set) var voipToken: String?
    private(set) var alertToken: String?
    private(set) var alertTokenError: String?
    private(set) var notificationsAuthorized: Bool?
    private(set) var timeSensitiveEnabled: Bool?

    @ObservationIgnored private var registry: PKPushRegistry?
    private let pushKitDelegate = PushKitDelegate()
    /// What was last uploaded in this process (deliberately not persisted: every start re-sends).
    @ObservationIgnored private var uploaded: String?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var again = false

    /// Called from `application(_:didFinishLaunchingWithOptions:)`: the registry must
    /// exist before PushKit delivers a VoIP push to an app it launched.
    func start() {
        guard registry == nil else { return }
        pushKitDelegate.owner = self
        let r = PKPushRegistry(queue: .main)
        r.delegate = pushKitDelegate
        r.desiredPushTypes = [.voIP]
        registry = r
        if let token = r.pushToken(for: .voIP) { voipToken = token.hexString }
        UIApplication.shared.registerForRemoteNotifications()
    }

    // MARK: - Tokens

    fileprivate func voipTokenChanged(_ token: String?) {
        guard token != voipToken else { return }
        voipToken = token
        Task { await ensureRegistered() }
    }

    func alertTokenReceived(_ deviceToken: Data) {
        alertTokenError = nil
        let token = deviceToken.hexString
        guard token != alertToken else { return }
        alertToken = token
        Task { await ensureRegistered() }
    }

    func alertTokenFailed(_ error: Error) {
        Log.push.error("APNs registration failed: \(Strings.describe(error), privacy: .public)")
        alertTokenError = Strings.describe(error)
    }

    /// Both tokens for the pair request, when iOS already gave them (the pairing's
    /// `push_config` isn't known yet, so a gateway relay gets the handle right after).
    /// The pairing changed: the next `ensureRegistered` uploads again.
    func pairingChanged() {
        uploaded = nil
        state = .notConfigured
    }

    // MARK: - Upload

    /// Makes sure the relay (or the gateway) has our current tokens.
    func ensureRegistered() async {
        if running {
            again = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            again = false
            await registerOnce()
        } while again
    }

    private func registerOnce() async {
        let model = AppModel.shared
        guard let p = model.pairing, !model.revoked else {
            state = .notConfigured
            return
        }
        guard let config = p.push, config.provider == "apns" else {
            state = .notConfigured
            return
        }
        if let topic = config.topic, topic != AppInfo.bundleId {
            state = .topicMismatch(topic)
            return
        }
        guard let voip = voipToken, let alert = alertToken else {
            state = .waitingForTokens
            return
        }
        let env = AppInfo.apnsEnvironment
        let key = [p.deviceId, voip, alert, env, String(config.viaGateway), config.gatewayUrl ?? ""].joined(separator: "|")
        if uploaded == key {
            state = .registered
            return
        }
        state = .registering
        let tokens = ApnsTokens(voipToken: voip, alertToken: alert, environment: env, topic: AppInfo.bundleId)
        do {
            guard let api = model.api() else { return }
            if config.viaGateway {
                guard let gatewayUrl = config.gatewayUrl, !gatewayUrl.isEmpty else {
                    state = .error("the relay uses a push gateway but sent no gateway_url")
                    return
                }
                try RelayUrlPolicy.check(gatewayUrl)
                let handle = try await PushGatewayClient.register(gatewayUrl: gatewayUrl, tokens: tokens)
                try await api.updatePushTokens(apns: ApnsTokens(gatewayHandle: handle))
            } else {
                try await api.updatePushTokens(apns: tokens)
            }
            // The pairing may have changed while uploading.
            guard model.pairing?.deviceId == p.deviceId else { return }
            uploaded = key
            state = .registered
            Log.push.info("push tokens registered (\(config.viaGateway ? "gateway" : "direct", privacy: .public), \(env, privacy: .public))")
        } catch let e as RelayError {
            if e.isUnauthorized { model.markRevoked() }
            state = .error(e.message)
        } catch {
            state = .error(Strings.describe(error))
        }
    }

    // MARK: - Notification permission

    func refreshNotificationSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationsAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
            || settings.authorizationStatus == .ephemeral
        timeSensitiveEnabled = settings.timeSensitiveSetting == .enabled
    }

    func requestNotificationPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshNotificationSettings()
        UIApplication.shared.registerForRemoteNotifications()
    }
}

/// `PKPushRegistryDelegate` on the main queue (`PKPushRegistry(queue: .main)`).
private final class PushKitDelegate: NSObject, PKPushRegistryDelegate {
    weak var owner: PushRegistrar?

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.hexString
        MainActor.assumeIsolated { self.owner?.voipTokenChanged(token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated { self.owner?.voipTokenChanged(nil) }
    }

    /// Every VoIP push must be reported to CallKit before `completion` runs, or iOS
    /// stops delivering them: `CallController.handleVoipPush` always does.
    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let userInfo = payload.dictionaryPayload
        MainActor.assumeIsolated {
            AppModel.shared.calls.handleVoipPush(userInfo, completion: completion)
        }
    }
}
