import AVFoundation
import SwiftUI
import UIKit

/// Welcome → permissions → pairing (much shorter than Android's: no battery,
/// full-screen intent or OEM steps on iOS).
struct OnboardingFlow: View {
    let model: AppModel
    @State private var step: Step = .welcome

    enum Step { case welcome, permissions, pair }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeView { step = .permissions }
            case .permissions:
                PermissionsView(model: model) {
                    model.setIntroSeen()
                    step = .pair
                }
            case .pair:
                PairView(model: model)
            }
        }
        .onAppear { if model.introSeen { step = .pair } }
    }
}

private struct WelcomeView: View {
    let next: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "phone.and.waveform.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
            Text("Your AI agent can call you")
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text("Claude Code, Codex, OpenClaw, n8n or your own scripts can message you and ring your phone like a real call. No phone number needed.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 16) {
                feature("message.fill", "Messages", "Your agent texts you. Reply straight from the notification.")
                feature("phone.fill", "Real calls", "It rings even with the phone locked, like any call.")
                feature("phone.arrow.up.right.fill", "Call it back", "Tap once to talk to your agent by voice.")
            }
            .padding(.top, 8)
            Spacer()
            Button("Get started", action: next).buttonStyle(PrimaryButtonStyle())
            Text("Setup takes about 2 minutes.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func feature(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(body).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }
}

/// Notifications (alerts; time-sensitive comes with the entitlement) and microphone.
struct PermissionsView: View {
    let model: AppModel
    let next: () -> Void
    @State private var mic = AVAudioApplication.shared.recordPermission
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Ready to take calls").font(.largeTitle.bold())
                Text("Your agent's calls should ring even with the phone locked. Allow what's missing below.")
                    .foregroundStyle(.secondary)
                Card {
                    permissionRow(
                        title: "Notifications",
                        why: "To show messages and missed calls.",
                        granted: model.push.notificationsAuthorized
                    ) {
                        Task { await model.push.requestNotificationPermission() }
                    }
                    Divider()
                    permissionRow(
                        title: "Microphone",
                        why: "So your agent can hear you.",
                        granted: mic == .undetermined ? nil : mic == .granted
                    ) {
                        requestMic()
                    }
                }
                Card {
                    Label("Focus and silent mode", systemImage: "moon.fill").font(.headline)
                    Text("Calls follow the ring/silent switch and Focus like any phone call. To let urgent calls through a Focus, add agentring to its allowed apps (Settings → Focus → People / Apps) and keep Time Sensitive Notifications on.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: next)
                .buttonStyle(PrimaryButtonStyle())
                .padding(24)
                .background(.bar)
        }
        .task { await model.push.refreshNotificationSettings() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                mic = AVAudioApplication.shared.recordPermission
                Task { await model.push.refreshNotificationSettings() }
            }
        }
    }

    private func requestMic() {
        if mic == .denied {
            openSettings()
            return
        }
        AVAudioApplication.requestRecordPermission { _ in
            onMain { mic = AVAudioApplication.shared.recordPermission }
        }
    }

    @ViewBuilder
    private func permissionRow(title: String, why: String, granted: Bool?, request: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(why).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if granted == true {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusColors.ok).font(.title2)
            } else if granted == false {
                Button("Settings", action: openSettings).buttonStyle(.bordered)
            } else {
                Button("Allow", action: request).buttonStyle(.borderedProminent)
            }
        }
    }
}

func openSettings() {
    if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
    }
}

/// Shown right after pairing (Android's "done" screen).
struct PairedView: View {
    let model: AppModel

    var body: some View {
        let agent = model.pairing?.agentName ?? "your agent"
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(StatusColors.ok)
                Text("Paired with \(agent)").font(.largeTitle.bold())
                Text("Your phone is ready. Let's try it.").foregroundStyle(.secondary)
                if let warning = PushWarning.text(model) {
                    Card {
                        Label("Push", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(StatusColors.warn)
                        Text(warning).font(.subheadline)
                    }
                }
                Card {
                    Text("Try it").font(.headline)
                    StepRow(number: 1, title: "Send yourself a message", detail: "On the computer that runs your agent:",
                            code: "agentring msg \"hello from my agent\"")
                    StepRow(number: 2, title: "Make a test call", detail: "Lock the phone first: it should ring like a call.",
                            code: "agentring call \"test\"")
                    StepRow(number: 3, title: "Connect your agent", detail: "For example, Claude Code:",
                            code: "claude mcp add agentring -- agentring mcp")
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Continue") { model.setSetupComplete(true) }
                .buttonStyle(PrimaryButtonStyle())
                .padding(24)
                .background(.bar)
        }
    }
}
