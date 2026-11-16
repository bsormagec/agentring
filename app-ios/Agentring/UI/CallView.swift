import SwiftUI

/// In-app call screen (the system CallKit UI covers the lock screen and other apps).
/// Unlike the lock screen, it shows the call reason.
struct CallView: View {
    let calls: CallController

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.11, blue: 0.19), Color(red: 0.04, green: 0.05, blue: 0.10)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            if let s = calls.state {
                content(s)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func content(_ s: CallUi) -> some View {
        VStack(spacing: 16) {
            Spacer().frame(height: 40)
            if s.info.urgent {
                Text("URGENT")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(StatusColors.bad, in: Capsule())
            }
            AgentAvatar(name: s.info.agentName, size: 96)
            Text(s.info.agentName).font(.largeTitle.bold())
            status(s).font(.title3).foregroundStyle(.secondary)
            if !s.info.reason.isEmpty {
                Text(s.info.reason)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 32)
                    .lineLimit(6)
            }
            Spacer()
            controls(s)
                .padding(.bottom, 48)
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func status(_ s: CallUi) -> some View {
        switch s.phase {
        case .incoming: Text(Strings.callIncoming)
        case .outgoing: Text(Strings.calling(s.info.agentName))
        case .connecting: Text(Strings.callConnecting)
        case .ended: Text(s.endMessage ?? Strings.callEnded)
        case .active:
            if s.reconnecting {
                Text(Strings.callReconnecting)
            } else if let since = s.since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date)).monospacedDigit()
                }
            } else {
                Text("")
            }
        }
    }

    @ViewBuilder
    private func controls(_ s: CallUi) -> some View {
        switch s.phase {
        case .incoming:
            HStack(spacing: 80) {
                RoundButton(icon: "phone.down.fill", label: "Decline", color: StatusColors.bad) { calls.hangUp() }
                RoundButton(icon: "phone.fill", label: "Answer", color: StatusColors.ok) { calls.answer() }
            }
        case .ended:
            EmptyView()
        default:
            VStack(spacing: 32) {
                HStack(spacing: 48) {
                    RoundButton(icon: s.muted ? "mic.slash.fill" : "mic.fill", label: "Mute",
                                color: s.muted ? Color.white : Color.white.opacity(0.18),
                                iconColor: s.muted ? Color.black : Color.white) { calls.toggleMute() }
                    RoundButton(icon: "speaker.wave.2.fill", label: "Speaker",
                                color: s.speaker ? Color.white : Color.white.opacity(0.18),
                                iconColor: s.speaker ? Color.black : Color.white) { calls.toggleSpeaker() }
                }
                RoundButton(icon: "phone.down.fill", label: "Hang up", color: StatusColors.bad) { calls.hangUp() }
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let total = max(0, Int(now.timeIntervalSince(start)))
        let h = total / 3600, m = (total % 3600) / 60, sec = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

private struct RoundButton: View {
    let icon: String
    let label: String
    let color: Color
    var iconColor: Color = .white
    let action: () -> Void

    init(icon: String, label: String, color: Color, iconColor: Color = .white, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.color = color
        self.iconColor = iconColor
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 72, height: 72)
                    .background(color, in: Circle())
            }
            .accessibilityLabel(label)
            Text(label).font(.footnote).foregroundStyle(.white.opacity(0.8))
        }
    }
}
