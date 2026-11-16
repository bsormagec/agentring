import AVFoundation
import CallKit
import CryptoKit
import Foundation
import LiveKit
import Observation
import AgentringCore

/// What the call screen shows about a call.
struct CallInfo: Equatable, Sendable {
    let callId: String
    let agentName: String
    let reason: String
    let urgent: Bool
    /// Ring deadline (ms since the epoch); 0 when unknown.
    let expiresAt: Int64

    init(callId: String, agentName: String, reason: String, urgent: Bool, expiresAt: Int64) {
        self.callId = callId
        self.agentName = agentName
        self.reason = reason
        self.urgent = urgent
        self.expiresAt = expiresAt
    }

    init(_ call: Call) {
        self.init(callId: call.callId, agentName: call.agentName, reason: call.reason ?? "",
                  urgent: call.priority == "urgent", expiresAt: 0)
    }

    init(_ invite: Event.CallInvite) {
        self.init(callId: invite.callId, agentName: invite.agentName, reason: invite.reason,
                  urgent: invite.priority == "urgent", expiresAt: invite.expiresAt)
    }
}

/// A group call from the agent in progress that this phone is not on: it can join.
struct JoinOffer: Equatable, Sendable {
    let info: CallInfo
    /// When the call was first answered (ms since the epoch), for a timer.
    let answeredAt: Int64?
}

enum CallPhase: Equatable {
    case incoming
    /// This phone called the agent: in the room, waiting for the agent to pick up.
    case outgoing
    case connecting
    case active
    case ended
}

struct CallUi: Equatable {
    var info: CallInfo
    var phase: CallPhase
    /// When audio started, for the timer.
    var since: Date?
    var muted = false
    var speaker = false
    var reconnecting = false
    /// Why the call ended (shown briefly before the call screen closes).
    var endMessage: String?

    var isLive: Bool { phase != .ended }
}

/// The one call: ringing, answering, calling the agent, joining, the voice session and
/// hanging up, around CallKit (`CXProvider` + `CXCallController`). Mirrors
/// app-android's `CallManager`.
///
/// Incoming calls come from a PushKit VoIP push (reported to CallKit before anything
/// else, then verified) or from the WebSocket while the app runs; both use the same
/// CallKit UUID derived from the call id, so a call never rings twice. There is no
/// VoIP push for "stop ringing": while it rings the app keeps the WebSocket open,
/// polls `GET /v1/calls/{id}` every 2 s and ends the ring itself at `expires_at`.
///
/// CallKit owns the audio session and the ringtone. LiveKit's own session handling is
/// off; its audio engine runs only between `didActivate` and `didDeactivate`.
@MainActor
@Observable
final class CallController {
    private(set) var state: CallUi?
    private(set) var joinable: JoinOffer?

    /// The call this phone may join, while it is not on a call itself.
    var joinOffer: JoinOffer? { isIdle ? joinable : nil }
    var isIdle: Bool { state.map { !$0.isLive } ?? true }

    private let provider: CXProvider
    private let callKit = CXCallController()
    private let providerDelegate = ProviderDelegate()
    private let audioQueue = DispatchQueue(label: "dev.agentring.audio-engine")
    /// CallKit UUID of the current call.
    @ObservationIgnored private var callUUID: UUID?
    /// CallKit knows the current call (reported incoming, or its start action performed).
    @ObservationIgnored private var reportedToCallKit = false
    /// The current call was started with `CXStartCallAction` (calling the agent, joining).
    @ObservationIgnored private var outgoingCallKit = false
    /// CallKit wouldn't start the call: the app activated the audio session itself.
    @ObservationIgnored private var manualAudio = false
    @ObservationIgnored private var pendingAnswer: CXAnswerCallAction?
    /// A WebSocket invite being checked with the relay before it rings.
    @ObservationIgnored private var pendingIncoming: String?
    /// Calls already handled, so a second copy of an invite (push + WebSocket) doesn't ring again.
    @ObservationIgnored private var seen: [String] = []
    @ObservationIgnored private var session: VoiceSession?
    /// Work that lives as long as the current call.
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// This phone is in the LiveKit room.
    @ObservationIgnored private var inRoom = false
    @ObservationIgnored private var routeObserver: NSObjectProtocol?

    private static let clockSkewMs: Int64 = 5_000
    private static let endedLinger: Double = 2
    private static let pollSeconds: Double = 2
    /// Well past the relay's ring timeout (30 s by default).
    private static let outgoingGiveUpSeconds: Double = 75
    private static let connectTimeoutSeconds: Double = 10
    private static let lastLiveKitUrlKey = "last_livekit_url"

    init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        provider = CXProvider(configuration: config)

        // CallKit owns the audio session: LiveKit must neither configure it nor start
        // its audio engine outside CallKit's didActivate / didDeactivate window.
        AudioManager.shared.audioSession.isAutomaticConfigurationEnabled = false
        do {
            try AudioManager.shared.setEngineAvailability(.none)
        } catch {
            Log.calls.error("setEngineAvailability(.none) failed: \(String(describing: error), privacy: .public)")
        }

        providerDelegate.owner = self
        provider.setDelegate(providerDelegate, queue: nil)
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            onMain { self?.routeChanged() }
        }
    }

    // MARK: - Helpers

    private var api: RelayApi? { AppModel.shared.api() }

    private func isCurrent(_ callId: String) -> Bool { state?.info.callId == callId }

    private func isLive(_ callId: String) -> Bool {
        guard let s = state else { return false }
        return s.info.callId == callId && s.isLive
    }

    private func remember(_ callId: String) {
        seen.removeAll { $0 == callId }
        seen.append(callId)
        if seen.count > 50 { seen.removeFirst(seen.count - 50) }
    }

    private static var micGranted: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    /// The CallKit UUID of an agent call: derived from the call id, so the VoIP push and
    /// the WebSocket report the same call.
    static func uuid(for callId: String) -> UUID {
        let digest = SHA256.hash(data: Data("agentring.call.\(callId)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50 // version 5 (name-based)
        b[8] = (b[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private func callUpdate(name: String) -> CXCallUpdate {
        // Lock-screen privacy: only the agent's name, never the call reason.
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    private func cancelTasks() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Asks CallKit to perform `action`; runs `fallback` when CallKit refuses.
    private func request(_ action: CXCallAction, fallback: @escaping @MainActor () -> Void) {
        callKit.request(CXTransaction(action: action)) { error in
            guard let error else { return }
            Log.calls.error("CallKit refused \(String(describing: type(of: action)), privacy: .public): \(String(describing: error), privacy: .public)")
            onMain { fallback() }
        }
    }

    // MARK: - Incoming: VoIP push

    private enum PushDecision {
        case ring(Event.CallInvite)
        case end(CXCallEndedReason, String)
    }

    /// Handles a PushKit VoIP push. iOS requires every VoIP push to report a call to
    /// CallKit before `completion` runs, so the call is reported first and verified
    /// after; a push that fails verification is ended at once without ringing on.
    func handleVoipPush(_ userInfo: [AnyHashable: Any], completion: @escaping () -> Void) {
        guard case .callInvite(let invite)? = PushVerifier.peekEvent(apnsUserInfo: userInfo) else {
            Log.calls.error("VoIP push without a call.invite: reporting and ending it")
            let uuid = UUID()
            provider.reportNewIncomingCall(with: uuid, update: callUpdate(name: "agentring")) { [provider] _ in
                provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                completion()
            }
            return
        }
        let uuid = Self.uuid(for: invite.callId)

        // The same call is already showing (the WebSocket was faster, or a duplicate
        // push): the report fails with callUUIDAlreadyExists, which is fine.
        if isLive(invite.callId) {
            provider.reportNewIncomingCall(with: uuid, update: callUpdate(name: invite.agentName)) { _ in completion() }
            return
        }
        if pendingIncoming == invite.callId { pendingIncoming = nil } // the push takes over from the WebSocket check

        let decision = DecisionBox()
        provider.reportNewIncomingCall(with: uuid, update: callUpdate(name: invite.agentName)) { error in
            onMain { [self] in
                defer { completion() }
                if let error {
                    // Filtered by Focus / Do Not Disturb, or blocked: nothing rings, the relay times it out.
                    Log.calls.notice("CallKit didn't take \(invite.callId, privacy: .public): \(String(describing: error), privacy: .public)")
                    return
                }
                switch decision.value {
                case .ring(let verified):
                    startIncoming(verified, uuid: uuid)
                case .end(let reason, let why):
                    Log.calls.warning("ending VoIP call \(invite.callId, privacy: .public): \(why, privacy: .public)")
                    provider.reportCall(with: uuid, endedAt: nil, reason: reason)
                }
            }
        }
        // Verified right after reporting (quick, nothing from the network). The completion
        // above runs later, on the main queue, so it sees the result.
        decision.value = decide(userInfo, peeked: invite)
    }

    /// Holds the verification result for the report's completion (main thread only).
    private final class DecisionBox: @unchecked Sendable {
        var value: PushDecision = .end(.failed, "not verified")
    }

    private func decide(_ userInfo: [AnyHashable: Any], peeked: Event.CallInvite) -> PushDecision {
        // Before the first unlock after a reboot the Keychain can't be read: can't verify.
        guard let p = AppModel.shared.pairing ?? PairingStore.current() else {
            return .end(.failed, "not paired, or the Keychain is locked")
        }
        let invite: Event.CallInvite
        switch PushVerifier.verify(apnsUserInfo: userInfo, expectedRelayId: p.relayId, pushSecret: p.pushSecret) {
        case .rejected(let why):
            return .end(.failed, "rejected: \(why)")
        case .ok(let event):
            guard case .callInvite(let verified) = event, verified.callId == peeked.callId else {
                return .end(.failed, "not a call.invite")
            }
            invite = verified
        }
        if invite.direction != "agent_to_user" { return .end(.failed, "direction \(invite.direction)") }
        if nowMs() > invite.expiresAt + Self.clockSkewMs { return .end(.unanswered, "expired") }
        if !isIdle { return .end(.failed, "already on a call") }
        if seen.contains(invite.callId) { return .end(.remoteEnded, "already handled") }
        return .ring(invite)
    }

    // MARK: - Incoming: WebSocket

    /// An invite from the WebSocket (app running). It may be a replay of an invite that
    /// was answered or canceled since, so the relay is asked first.
    func onSocketInvite(_ invite: Event.CallInvite) {
        guard invite.direction == "agent_to_user" else { return } // our own call to the agent
        guard nowMs() <= invite.expiresAt + Self.clockSkewMs else { return }
        guard isIdle, !seen.contains(invite.callId), pendingIncoming != invite.callId else { return }
        pendingIncoming = invite.callId
        Task {
            let call = try? await self.api?.getCall(invite.callId)
            guard self.pendingIncoming == invite.callId else { return } // a VoIP push took over
            self.pendingIncoming = nil
            guard call?.isRinging == true, self.isIdle, !self.seen.contains(invite.callId) else { return }
            let uuid = Self.uuid(for: invite.callId)
            self.provider.reportNewIncomingCall(with: uuid, update: self.callUpdate(name: invite.agentName)) { error in
                onMain { [self] in
                    if let error {
                        Log.calls.notice("CallKit didn't take \(invite.callId, privacy: .public): \(String(describing: error), privacy: .public)")
                        return
                    }
                    if !isIdle && !isLive(invite.callId) {
                        provider.reportCall(with: uuid, endedAt: nil, reason: .failed)
                        return
                    }
                    startIncoming(invite, uuid: uuid)
                }
            }
        }
    }

    // MARK: - Ringing

    private func startIncoming(_ invite: Event.CallInvite, uuid: UUID) {
        if isLive(invite.callId) { return }
        let info = CallInfo(invite)
        remember(info.callId)
        pendingIncoming = nil
        if joinable?.info.callId != info.callId { setJoinable(nil) }
        cancelTasks()
        callUUID = uuid
        reportedToCallKit = true
        outgoingCallKit = false
        inRoom = false
        state = CallUi(info: info, phase: .incoming)
        AppModel.shared.connection.setCallActive(true)
        Log.calls.info("ringing \(info.callId, privacy: .public)")

        let api = self.api
        tasks.append(Task {
            for _ in 0..<2 {
                do {
                    try await api?.reportRinging(info.callId)
                    return
                } catch {
                    Log.calls.warning("report ringing failed: \(String(describing: error), privacy: .public)")
                }
            }
        })
        // Don't ring past the relay's deadline even if call.missed never arrives.
        tasks.append(Task {
            let wait = max(0, Double(info.expiresAt - nowMs() + 2_000) / 1000)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if Task.isCancelled { return }
            self.ringTimedOut(info)
        })
        tasks.append(Task { await self.pollIncoming(info) })

        // Build the WebRTC stack and warm the connection while the user decides.
        let s = VoiceSession()
        session = s
        attach(s, info)
        if let url = UserDefaults.standard.string(forKey: Self.lastLiveKitUrlKey) {
            Task { await s.prepare(url: url) }
        }
    }

    private func ringTimedOut(_ info: CallInfo) {
        guard isCurrent(info.callId), state?.phase == .incoming else { return }
        finish(info, Strings.callMissed, reason: .unanswered)
        // Another phone may have answered: then offer to join instead of a missed call.
        Task {
            if let call = try? await self.api?.getCall(info.callId), call.isJoinable {
                self.offerJoin(call)
            } else {
                Notifier.showMissed(info)
            }
        }
    }

    /// Backup for the WebSocket while ringing: no VoIP push says "stop ringing".
    private func pollIncoming(_ info: CallInfo) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
            guard !Task.isCancelled, isCurrent(info.callId), state?.phase == .incoming, let api = self.api else { return }
            do {
                let call = try await api.getCall(info.callId)
                guard isCurrent(info.callId), state?.phase == .incoming else { return }
                switch call.state {
                // Group calls: another phone answering doesn't stop this one ringing
                // (state "active"); it can still answer until expires_at.
                case "ended", "canceled":
                    finish(info, Strings.callMissed, reason: .remoteEnded, notifyMissed: true)
                case "missed":
                    finish(info, Strings.callMissed, reason: .unanswered, notifyMissed: true)
                case "declined":
                    finish(info, Strings.callEnded, reason: .declinedElsewhere)
                default:
                    break
                }
            } catch let e as RelayError where e.status == 403 || e.status == 404 {
                finish(info, Strings.callUnavailable, reason: .remoteEnded)
            } catch {
                // Network trouble: keep ringing, the timer ends it at expires_at.
            }
        }
    }

    // MARK: - Answer / decline / hang up

    /// The app's Answer button: goes through CallKit so the system UI follows.
    func answer() {
        guard let s = state, s.phase == .incoming, let uuid = callUUID else { return }
        request(CXAnswerCallAction(call: uuid)) { [weak self] in self?.performAnswer(nil) }
    }

    fileprivate func performAnswer(_ action: CXAnswerCallAction?) {
        guard let s = state, s.phase == .incoming, action == nil || action?.callUUID == callUUID else {
            action?.fail()
            return
        }
        let info = s.info
        cancelTasks()
        pendingAnswer = action
        configureAudioSession()
        state?.phase = .connecting
        Task {
            let join: JoinInfo
            do {
                join = try await self.acceptOrJoin(info.callId)
            } catch let e as RelayError {
                Log.calls.warning("accept failed: \(e.code, privacy: .public)")
                let gone = e.code == "invalid_state" || e.code == "call_ended"
                self.finish(info, gone ? Strings.callUnavailable : Strings.callFailed, reason: .failed)
                return
            } catch {
                Log.calls.warning("accept failed: \(String(describing: error), privacy: .public)")
                self.finish(info, Strings.callFailed, reason: .failed)
                return
            }
            await self.connect(info, join)
        }
    }

    /// Accept while ringing; if the ring window closed meanwhile, join the call instead.
    private func acceptOrJoin(_ callId: String) async throws -> JoinInfo {
        guard let api = self.api else { throw CoreError("Not paired") }
        do {
            return try await api.acceptCall(callId).join
        } catch let e as RelayError where e.code == "invalid_state" {
            return try await api.joinCall(callId).join
        }
    }

    /// The app's hang-up button: decline while ringing, cancel while calling, leave otherwise.
    func hangUp() {
        guard let s = state, s.isLive else { return }
        if reportedToCallKit, let uuid = callUUID {
            request(CXEndCallAction(call: uuid)) { [weak self] in self?.endByUser(nil) }
        } else {
            endByUser(nil)
        }
    }

    fileprivate func performEnd(_ action: CXEndCallAction) {
        guard action.callUUID == callUUID else {
            // A call CallKit still lists but we're done with.
            action.fulfill()
            return
        }
        endByUser(action)
    }

    /// The user ended the call (CallKit's button, the app's, a headset).
    private func endByUser(_ action: CXEndCallAction?) {
        guard let s = state, s.isLive else {
            action?.fulfill()
            return
        }
        let info = s.info
        let api = self.api
        // Without a CallKit action (CallKit refused the request) CallKit must still hear of it.
        let reason: CXCallEndedReason? = action == nil ? .remoteEnded : nil
        if s.phase == .incoming {
            // If another phone is already on the call, this one can still join it later.
            Task {
                if let call = try? await api?.declineCall(info.callId) { self.offerJoin(call) }
            }
            finish(info, Strings.callDeclined, reason: reason)
        } else {
            // While calling the agent this cancels the call (relay: `canceled`); in a group
            // call the others may still be on it, so this phone can rejoin.
            Task {
                if let call = try? await api?.endCall(info.callId) { self.offerJoin(call) }
            }
            finish(info, Strings.callEnded, reason: reason)
        }
        action?.fulfill()
    }

    // MARK: - Calling the agent (M4)

    /// Calls the agent. Returns nil once the call is ringing (the call screen opens), or
    /// a message to show under the button when it could not be placed.
    func callAgent() async -> String? {
        if let s = state, s.isLive {
            return (s.phase == .outgoing || s.phase == .active) ? nil : Strings.agentBusy
        }
        guard let api = self.api else { return Strings.needsRelay }
        let created: CallWithJoin
        do {
            created = try await api.createCall()
        } catch let e as RelayError {
            Log.calls.warning("create call failed: \(e.status) \(e.code, privacy: .public)")
            switch e.code {
            case "agent_offline": return Strings.agentOffline
            case "busy": return Strings.agentBusy
            case "quota_exceeded": return Strings.agentQuota
            case "calls_unavailable": return Strings.callsUnavailable
            default: return Strings.callFailed
            }
        } catch {
            Log.calls.warning("create call failed: \(String(describing: error), privacy: .public)")
            return Strings.callFailed
        }
        let call = created.call
        let info = CallInfo(call)
        remember(call.callId)
        if !isIdle {
            // An agent call came in meanwhile: give up ours.
            _ = try? await api.endCall(call.callId)
            return Strings.agentBusy
        }
        setJoinable(nil)
        cancelTasks()
        inRoom = false
        callUUID = UUID()
        outgoingCallKit = true
        reportedToCallKit = false
        state = CallUi(info: info, phase: .outgoing)
        AppModel.shared.connection.setCallActive(true)
        configureAudioSession()
        Log.calls.info("calling the agent: \(call.callId, privacy: .public)")
        startCallKitCall(info)
        tasks.append(Task { await self.pollOutgoing(info) })
        Task { await self.connect(info, created.join) }
        return nil
    }

    /// `CXStartCallAction` for a call this phone starts (the agent call, a join), so
    /// the system knows a call is on (Recents, CarPlay, the audio session).
    private func startCallKitCall(_ info: CallInfo) {
        guard let uuid = callUUID else { return }
        let action = CXStartCallAction(call: uuid, handle: CXHandle(type: .generic, value: info.agentName))
        action.isVideo = false
        request(action) { [weak self] in
            guard let self, self.isLive(info.callId), self.callUUID == uuid else { return }
            // No CallKit call: run the audio session ourselves.
            self.activateAudioManually()
        }
    }

    fileprivate func performStart(_ action: CXStartCallAction) {
        guard let uuid = callUUID, action.callUUID == uuid, let s = state, s.isLive else {
            action.fail()
            return
        }
        reportedToCallKit = true
        action.fulfill()
        provider.reportOutgoingCall(with: uuid, startedConnectingAt: Date())
        provider.reportCall(with: uuid, updated: callUpdate(name: s.info.agentName))
        // The agent picked up before CallKit got here.
        if s.phase == .active { provider.reportOutgoingCall(with: uuid, connectedAt: Date()) }
    }

    /// Backup for the WebSocket while calling: the relay doesn't push events of calls
    /// to the agent, and the socket may be down.
    private func pollOutgoing(_ info: CallInfo) async {
        let deadline = Date().addingTimeInterval(Self.outgoingGiveUpSeconds)
        while !Task.isCancelled, isCurrent(info.callId), state?.phase == .outgoing {
            try? await Task.sleep(nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
            guard !Task.isCancelled, isCurrent(info.callId), state?.phase == .outgoing else { return }
            if Date() > deadline {
                // The relay's ring timer should have ended it long ago; don't ring forever.
                _ = try? await api?.endCall(info.callId)
                finish(info, Strings.agentNoAnswer, reason: .unanswered)
                return
            }
            guard let call = try? await api?.getCall(info.callId) else { continue }
            onOutgoingState(info.callId, call.state)
        }
    }

    /// The relay's state of the call this phone placed.
    private func onOutgoingState(_ callId: String, _ relayState: String) {
        guard let s = state, s.info.callId == callId, s.isLive else { return }
        switch relayState {
        case "active": onAgentAnswered(callId)
        case "declined": finish(s.info, Strings.agentDeclined, reason: .remoteEnded)
        case "missed": finish(s.info, Strings.agentNoAnswer, reason: .unanswered)
        case "canceled", "ended": finish(s.info, Strings.callEnded, reason: .remoteEnded)
        default: break
        }
    }

    private func onAgentAnswered(_ callId: String) {
        guard let s = state, s.phase == .outgoing, s.info.callId == callId else { return }
        Log.calls.info("the agent answered \(callId, privacy: .public)")
        // Not in the room yet: connect() finishes the switch to active.
        if inRoom { goActive(s.info) } else { state?.phase = .connecting }
    }

    // MARK: - Join a group call

    /// "Join the call": gets this phone into an agent call in progress that it is not on.
    func join(_ offer: JoinOffer) async {
        let info = offer.info
        if let s = state, s.isLive {
            if s.phase == .incoming, s.info.callId == info.callId { answer() }
            return
        }
        guard let api = self.api else { return }
        remember(info.callId) // a replayed invite must not ring now
        setJoinable(nil)
        Notifier.cancelJoin(info.callId)
        cancelTasks()
        inRoom = false
        callUUID = UUID()
        outgoingCallKit = true
        reportedToCallKit = false
        state = CallUi(info: info, phase: .connecting)
        AppModel.shared.connection.setCallActive(true)
        configureAudioSession()
        let join: JoinInfo
        do {
            join = try await api.joinCall(info.callId).join
        } catch {
            Log.calls.warning("join failed: \(String(describing: error), privacy: .public)")
            let over = (error as? RelayError)?.code == "call_ended"
            finish(info, over ? Strings.callUnavailable : Strings.callFailed, reason: nil)
            if !over { recheckJoinable(info.callId) }
            return
        }
        guard isCurrent(info.callId), state?.phase == .connecting else {
            // Hung up before the relay answered: leave again so the relay doesn't count us in.
            if let call = try? await api.endCall(info.callId) { offerJoin(call) }
            return
        }
        Log.calls.info("joining \(info.callId, privacy: .public)")
        startCallKitCall(info)
        await connect(info, join)
    }

    // MARK: - Voice session

    /// Joins the LiveKit room with a fresh token, for an answered, placed or joined call.
    private func connect(_ info: CallInfo, _ join: JoinInfo) async {
        do {
            try RelayUrlPolicy.checkLiveKit(join.livekitUrl)
        } catch {
            Log.calls.error("refusing LiveKit URL from relay: \(Strings.describe(error), privacy: .public)")
            let api = self.api
            Task { _ = try? await api?.endCall(info.callId) }
            finish(info, Strings.callFailed, reason: .failed)
            return
        }
        UserDefaults.standard.set(join.livekitUrl, forKey: Self.lastLiveKitUrlKey)
        let s: VoiceSession
        if let existing = session {
            s = existing
        } else {
            s = VoiceSession()
            session = s
        }
        attach(s, info)
        if state?.muted == true { s.setMuted(true) }
        let started = Date()
        let withMic = Self.micGranted
        do {
            try await withDeadline(seconds: Self.connectTimeoutSeconds) {
                try await s.connect(url: join.livekitUrl, token: join.livekitToken, withMic: withMic)
            }
        } catch {
            guard isLive(info.callId) else { return } // hung up meanwhile
            Log.calls.warning("LiveKit connect failed: \(String(describing: error), privacy: .public)")
            let call = try? await api?.endCall(info.callId)
            finish(info, Strings.callFailed, reason: .failed)
            if let call { offerJoin(call) }
            return
        }
        Log.calls.info("in the room after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        guard isLive(info.callId), let phase = state?.phase else { return }
        inRoom = true
        switch phase {
        case .connecting: goActive(info)
        // Calling the agent: stay "Calling…" until it picks up, unless it already did.
        case .outgoing: if s.agentInRoom { onAgentAnswered(info.callId) }
        default: break
        }
    }

    private func attach(_ s: VoiceSession, _ info: CallInfo) {
        s.onSignal = { [weak self] signal in self?.voiceSignal(signal, info) }
        s.onAgentInRoom = { [weak self] in
            guard let self, self.inRoom else { return }
            self.onAgentAnswered(info.callId)
        }
    }

    private func voiceSignal(_ signal: VoiceSession.Signal, _ info: CallInfo) {
        guard let s = state, s.info.callId == info.callId, s.isLive else { return }
        switch signal {
        case .reconnecting:
            if s.phase == .active { state?.reconnecting = true }
        case .reconnected:
            state?.reconnecting = false
        case .gone(let why):
            Log.calls.info("voice session gone: \(why, privacy: .public)")
            let calling = s.phase == .outgoing
            let api = self.api
            Task {
                // Lost the connection while others are still talking: offer to rejoin.
                if let call = try? await api?.endCall(info.callId) { self.offerJoin(call) }
            }
            finish(info, calling ? Strings.callFailed : Strings.callEndedByAgent, reason: .remoteEnded)
        }
    }

    private func goActive(_ info: CallInfo) {
        guard isLive(info.callId) else { return }
        state?.phase = .active
        state?.since = Date()
        state?.speaker = AudioRoute.speakerOn
        pendingAnswer?.fulfill()
        pendingAnswer = nil
        if outgoingCallKit, reportedToCallKit, let uuid = callUUID {
            provider.reportOutgoingCall(with: uuid, connectedAt: Date())
        }
    }

    // MARK: - Mute and speaker

    func toggleMute() {
        guard let s = state, s.isLive, s.phase != .incoming else { return }
        let muted = !s.muted
        if reportedToCallKit, let uuid = callUUID {
            request(CXSetMutedCallAction(call: uuid, muted: muted)) { [weak self] in self?.setMuted(muted) }
        } else {
            setMuted(muted)
        }
    }

    fileprivate func performSetMuted(_ action: CXSetMutedCallAction) {
        guard action.callUUID == callUUID, state?.isLive == true else {
            action.fail()
            return
        }
        // Muted from the lock screen, CarPlay, AirPods or the app: follow it.
        setMuted(action.isMuted)
        action.fulfill()
    }

    private func setMuted(_ muted: Bool) {
        session?.setMuted(muted)
        state?.muted = muted
    }

    func toggleSpeaker() {
        guard let s = state, s.isLive, s.phase != .incoming else { return }
        let on = !s.speaker
        AudioRoute.setSpeaker(on)
        state?.speaker = on
    }

    private func routeChanged() {
        guard let s = state, s.isLive else { return }
        let on = AudioRoute.speakerOn
        if s.speaker != on { state?.speaker = on }
    }

    // MARK: - Audio session (CallKit)

    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        } catch {
            Log.calls.error("audio session category: \(String(describing: error), privacy: .public)")
        }
    }

    fileprivate func audioSessionActivated() {
        configureAudioSession()
        // Without microphone permission the engine may only play (LiveKit throws otherwise).
        let availability = Self.micGranted
            ? AudioEngineAvailability.default
            : AudioEngineAvailability(isInputAvailable: false, isOutputAvailable: true)
        audioQueue.async {
            do {
                try AudioManager.shared.setEngineAvailability(availability)
            } catch {
                Log.calls.error("setEngineAvailability failed: \(String(describing: error), privacy: .public)")
            }
        }
        if state?.isLive == true { state?.speaker = AudioRoute.speakerOn }
    }

    fileprivate func audioSessionDeactivated() {
        audioQueue.async {
            do {
                try AudioManager.shared.setEngineAvailability(.none)
            } catch {
                Log.calls.error("setEngineAvailability(.none) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func activateAudioManually() {
        guard !manualAudio else { return }
        manualAudio = true
        configureAudioSession()
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            Log.calls.error("audio session activation: \(String(describing: error), privacy: .public)")
        }
        audioSessionActivated()
    }

    private func deactivateManualAudio() {
        guard manualAudio else { return }
        manualAudio = false
        audioSessionDeactivated()
        audioQueue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    fileprivate func providerReset() {
        Log.calls.warning("CallKit provider reset")
        if let s = state, s.isLive {
            reportedToCallKit = false
            finish(s.info, Strings.callFailed, reason: nil)
        }
        audioSessionDeactivated()
    }

    // MARK: - Relay events

    /// Relay events (WebSocket or push) about a call this phone may be on or may join.
    func onCallEvent(_ event: Event) {
        switch event {
        case .callEnd(let e):
            if joinable?.info.callId == e.callId { setJoinable(nil) }
        case .callMissed(let m):
            if joinable?.info.callId == m.callId { setJoinable(nil) }
        case .callAccept(let a):
            // Another phone answered or joined an agent call: offer to join if we're not on it.
            if a.by == "user", a.deviceId != AppModel.shared.pairing?.deviceId,
               !isLive(a.callId), joinable?.info.callId != a.callId {
                recheckJoinable(a.callId)
            }
        default:
            break
        }
        guard let s = state else { return }
        let info = s.info
        if s.phase == .outgoing {
            switch event {
            case .callAccept(let a) where a.callId == info.callId: onOutgoingState(info.callId, "active")
            case .callDecline(let a) where a.callId == info.callId: onOutgoingState(info.callId, "declined")
            case .callMissed(let m) where m.callId == info.callId: onOutgoingState(info.callId, "missed")
            case .callEnd(let e) where e.callId == info.callId: onOutgoingState(info.callId, "ended")
            default: break
            }
            return
        }
        switch event {
        // Group calls: another phone answering or declining doesn't stop ours ringing.
        case .callEnd(let e) where e.callId == info.callId:
            let quota = e.reason == "quota" // the relay cut the call: the month's minutes ran out
            if !s.isLive {
                // The voice session may notice first ("the agent hung up"): say why instead.
                if quota { state?.endMessage = Strings.callEndedQuota }
            } else if s.phase == .incoming {
                finish(info, Strings.callMissed, reason: .remoteEnded, notifyMissed: true)
            } else {
                finish(info, quota ? Strings.callEndedQuota : Strings.callEndedByAgent, reason: .remoteEnded)
            }
        case .callMissed(let m) where m.callId == info.callId && s.phase == .incoming:
            finish(info, Strings.callMissed, reason: .unanswered, notifyMissed: true)
        default:
            break
        }
    }

    // MARK: - Join offer

    /// Offers "Join" for `call` if it is an agent call in progress and this phone is not on it.
    func offerJoin(_ call: Call) {
        guard call.isJoinable else {
            if joinable?.info.callId == call.callId { setJoinable(nil) }
            return
        }
        if isLive(call.callId) { return }
        setJoinable(JoinOffer(info: CallInfo(call), answeredAt: call.answeredAt))
    }

    private func setJoinable(_ offer: JoinOffer?) {
        if let old = joinable, old.info.callId != offer?.info.callId {
            Notifier.cancelJoin(old.info.callId)
        }
        joinable = offer
    }

    /// Asks the relay whether `callId` can be joined (events may be stale or replayed).
    func recheckJoinable(_ callId: String) {
        Task {
            if let call = try? await self.api?.getCall(callId) { self.offerJoin(call) }
        }
    }

    /// The relay's view of the open call (`active_call` in /v1/status), e.g. when the app
    /// comes to the foreground.
    func onActiveCall(_ call: Call?) {
        if let call { offerJoin(call) } else { setJoinable(nil) }
    }

    // MARK: - Teardown

    private func finish(_ info: CallInfo, _ message: String, reason: CXCallEndedReason?, notifyMissed: Bool = false) {
        guard isLive(info.callId) else { return }
        Log.calls.info("call \(info.callId, privacy: .public) finished: \(message, privacy: .public)")
        cancelTasks()
        session?.close()
        session = nil
        inRoom = false
        if let action = pendingAnswer {
            action.fail()
            pendingAnswer = nil
        }
        if let reason, reportedToCallKit, let uuid = callUUID {
            provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        }
        callUUID = nil
        reportedToCallKit = false
        outgoingCallKit = false
        deactivateManualAudio()
        AppModel.shared.connection.setCallActive(false)
        if notifyMissed { Notifier.showMissed(info) }
        var ended = state ?? CallUi(info: info, phase: .ended)
        ended.phase = .ended
        ended.reconnecting = false
        ended.endMessage = message
        state = ended
        let callId = info.callId
        Task {
            try? await Task.sleep(nanoseconds: UInt64(Self.endedLinger * 1_000_000_000))
            if let s = self.state, !s.isLive, s.info.callId == callId { self.state = nil }
        }
    }
}

// MARK: - CallKit delegate

/// `CXProviderDelegate` on the main queue (`setDelegate(_:queue: nil)`), forwarding to
/// the main-actor `CallController`.
private final class ProviderDelegate: NSObject, CXProviderDelegate {
    weak var owner: CallController?

    func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated { self.owner?.providerReset() }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            guard let owner = self.owner else { return action.fail() }
            owner.performAnswer(action)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            guard let owner = self.owner else { return action.fulfill() }
            owner.performEnd(action)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        MainActor.assumeIsolated {
            guard let owner = self.owner else { return action.fail() }
            owner.performStart(action)
        }
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            guard let owner = self.owner else { return action.fail() }
            owner.performSetMuted(action)
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { self.owner?.audioSessionActivated() }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        MainActor.assumeIsolated { self.owner?.audioSessionDeactivated() }
    }
}

/// Speakerphone on top of the CallKit-managed audio session.
enum AudioRoute {
    static var speakerOn: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    static func setSpeaker(_ on: Bool) {
        do {
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(on ? .speaker : .none)
        } catch {
            Log.calls.error("speaker override: \(String(describing: error), privacy: .public)")
        }
    }
}
