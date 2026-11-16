import Foundation
import Observation
import AgentringCore

/// Keeps the relay's event stream (`RelaySocket`) open while the app is in the
/// foreground or on a call (CallKit keeps the app running then). In the background
/// the phone relies on push instead.
@MainActor
@Observable
final class ConnectionManager {
    private(set) var relayState: RelaySocket.State = .disconnected
    /// From `agent.presence` / `GET /v1/status`; nil while unknown.
    private(set) var agentOnline: Bool?

    var isConnected: Bool { relayState == .connected }

    @ObservationIgnored private var socket: RelaySocket?
    /// Identifies the current socket: callbacks of a replaced one are ignored.
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var onCall = false

    private var wanted: Bool { foreground || onCall }

    func setForeground(_ on: Bool) {
        foreground = on
        update()
    }

    /// A call is ringing or on: keep the stream open even in the background.
    func setCallActive(_ on: Bool) {
        onCall = on
        update()
    }

    private func update() {
        if wanted { connect() } else { disconnect() }
    }

    func connect() {
        guard wanted, socket == nil else { return }
        let model = AppModel.shared
        guard let p = model.pairing, !model.revoked else { return }
        let api = RelayApi(baseUrl: p.relayUrl, deviceJwt: p.deviceJwt)
        let deviceId = p.deviceId
        let expectedRelayId = p.relayId
        let gen = UUID()
        generation = gen
        let s = RelaySocket(
            api: api,
            expectedRelayId: expectedRelayId,
            lastSeq: { AppModel.lastSeq(deviceId: deviceId) },
            onEvent: { event in
                onMain { AppModel.shared.connection.deliver(event, gen: gen, deviceId: deviceId) }
            },
            onState: { state in
                onMain { AppModel.shared.connection.stateChanged(state, gen: gen) }
            },
            onUnauthorized: {
                onMain { AppModel.shared.connection.unauthorized(gen: gen) }
            },
            onWrongRelay: { relayId in
                Log.relay.warning("the server says it is relay \(relayId, privacy: .public), we are paired with \(expectedRelayId, privacy: .public)")
            }
        )
        socket = s
        relayState = .connecting
        s.start()

        Task {
            do {
                try await model.refreshMessages()
                // A group call may be going on without this phone (missed ring, push lost): offer to join.
                let status = try await api.status()
                guard self.generation == gen else { return }
                self.agentOnline = status.agentOnline
                model.calls.onActiveCall(status.activeCall)
            } catch let e as RelayError {
                if e.isUnauthorized, self.generation == gen { model.markRevoked() }
            } catch {
                Log.relay.warning("refresh failed: \(Strings.describe(error), privacy: .public)")
            }
            await model.push.ensureRegistered()
        }
    }

    func disconnect() {
        socket?.stop()
        socket = nil
        generation = UUID()
        relayState = .disconnected
        agentOnline = nil
    }

    func reconnect() {
        disconnect()
        connect()
    }

    // MARK: - Socket callbacks (main actor)

    private func deliver(_ event: Event, gen: UUID, deviceId: String) {
        guard gen == generation else { return }
        let model = AppModel.shared
        switch event {
        case .callInvite(let invite):
            model.calls.onSocketInvite(invite)
        case .callAccept, .callDecline, .callEnd, .callMissed:
            model.calls.onCallEvent(event)
        case .agentPresence(let presence):
            agentOnline = presence.online
        default:
            break
        }
        model.apply(event, advanceSeq: true, deviceId: deviceId)
    }

    private func stateChanged(_ state: RelaySocket.State, gen: UUID) {
        guard gen == generation else { return }
        relayState = state
    }

    private func unauthorized(gen: UUID) {
        guard gen == generation else { return }
        AppModel.shared.markRevoked()
    }
}
