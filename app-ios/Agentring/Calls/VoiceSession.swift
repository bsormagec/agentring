import Foundation
import LiveKit

/// One LiveKit room for one call (a `Room` is never reused). Created while the phone
/// rings so the connection to the LiveKit server can be warmed up before the user
/// answers.
///
/// Audio: CallKit owns the `AVAudioSession`. `CallController` turns LiveKit's
/// automatic session handling off and opens / closes the audio engine with
/// `AudioManager.setEngineAvailability` in `provider(_:didActivate:)` /
/// `didDeactivate`, so connecting here never touches the audio device by itself.
@MainActor
final class VoiceSession {
    enum Signal {
        case reconnecting
        case reconnected
        /// The agent left or the connection is gone for good.
        case gone(String)
    }

    /// The relay's LiveKit identity for the agent (`identityOf` in relay/src/routes/calls.ts).
    static let agentIdentity = "agent"

    let room: Room
    var onSignal: ((Signal) -> Void)?
    /// The agent is in the room (for calls to the agent: it picked up).
    var onAgentInRoom: (() -> Void)?
    private(set) var agentInRoom = false

    private let observer = RoomObserver()
    private var closing = false
    private var connected = false
    private var wantMuted = false

    init() {
        room = Room()
        observer.owner = self
        room.add(delegate: observer)
    }

    /// Warms up DNS/TLS to the LiveKit server while the phone rings.
    func prepare(url: String) async {
        try? await room.prepareConnection(url: url)
    }

    /// Joins the room, publishing the microphone as part of the connection when allowed.
    func connect(url: String, token: String, withMic: Bool) async throws {
        let capture = AudioCaptureOptions(
            echoCancellation: true,
            autoGainControl: true,
            noiseSuppression: true,
            highpassFilter: true
        )
        // Voice, not music: 32 kbps Opus with DTX, plus redundancy (RED) against packet loss.
        let publish = AudioPublishOptions(encoding: AudioEncoding(maxBitrate: 32_000), dtx: true, red: true)
        let roomOptions = RoomOptions(
            defaultAudioCaptureOptions: capture,
            defaultAudioPublishOptions: publish,
            adaptiveStream: false,
            dynacast: false
        )
        let connectOptions = ConnectOptions(autoSubscribe: true, enableMicrophone: withMic)
        try await room.connect(url: url, token: token, connectOptions: connectOptions, roomOptions: roomOptions)
        if closing {
            // Hung up while connecting.
            await room.disconnect()
            throw CancellationError()
        }
        connected = true
        if wantMuted, withMic {
            _ = try? await room.localParticipant.setMicrophone(enabled: false)
        }
        // The agent may have joined before us: no participantDidConnect then.
        if room.remoteParticipants.values.contains(where: { $0.identity?.stringValue == Self.agentIdentity }) {
            markAgentHere()
        }
    }

    func setMuted(_ muted: Bool) {
        wantMuted = muted
        guard connected else { return }
        let room = self.room
        Task {
            do {
                _ = try await room.localParticipant.setMicrophone(enabled: !muted)
            } catch {
                Log.calls.error("setMicrophone(\(!muted)) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func close() {
        guard !closing else { return }
        closing = true
        onSignal = nil
        onAgentInRoom = nil
        room.remove(delegate: observer)
        let room = self.room
        Task { await room.disconnect() }
    }

    // MARK: - Room events (on the main actor)

    fileprivate func participantJoined(_ identity: String?) {
        if identity == Self.agentIdentity { markAgentHere() }
    }

    fileprivate func participantLeft(_ identity: String?) {
        Log.calls.info("\(identity ?? "?", privacy: .public) left the room")
        if identity == Self.agentIdentity, !closing { onSignal?(.gone("agent_left")) }
    }

    fileprivate func reconnecting() {
        if !closing { onSignal?(.reconnecting) }
    }

    fileprivate func reconnected() {
        if !closing { onSignal?(.reconnected) }
    }

    fileprivate func disconnected(_ reason: String) {
        if !closing { onSignal?(.gone("disconnected: \(reason)")) }
    }

    private func markAgentHere() {
        guard !agentInRoom else { return }
        agentInRoom = true
        onAgentInRoom?()
    }
}

/// LiveKit calls its delegates on its own queues; this hops to the main actor.
private final class RoomObserver: NSObject, RoomDelegate, @unchecked Sendable {
    weak var owner: VoiceSession?

    func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        onMain { self.owner?.participantJoined(identity) }
    }

    func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue
        onMain { self.owner?.participantLeft(identity) }
    }

    func roomIsReconnecting(_ room: Room) {
        onMain { self.owner?.reconnecting() }
    }

    func roomDidReconnect(_ room: Room) {
        onMain { self.owner?.reconnected() }
    }

    func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        let reason = error.map { String(describing: $0) } ?? "closed"
        onMain { self.owner?.disconnected(reason) }
    }
}
