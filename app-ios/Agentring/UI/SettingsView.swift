import SwiftUI
import UIKit

struct SettingsView: View {
    let model: AppModel
    @State private var confirmUnpair = false

    var body: some View {
        let push = model.push
        NavigationStack {
            List {
                if let p = model.pairing {
                    Section("Pairing") {
                        InfoRow(label: "Agent", value: p.agentName)
                        InfoRow(label: "Relay", value: p.relayUrl)
                        InfoRow(label: "Device ID", value: p.deviceId)
                    }
                }
                Section {
                    let state = push.state.label
                    StatusRow(label: "Push", value: state.0, color: state.1)
                    InfoRow(label: "VoIP token", value: push.voipToken == nil ? "Missing" : "OK")
                    InfoRow(label: "Notification token", value: push.alertToken == nil ? "Missing" : "OK")
                    InfoRow(label: "APNs environment", value: AppInfo.apnsEnvironment)
                    if let via = model.pairing?.push {
                        InfoRow(label: "Delivery", value: via.viaGateway ? "Push gateway" : "Direct (relay's APNs key)")
                    }
                    InfoRow(label: "Notifications", value: push.notificationsAuthorized == true ? "Allowed" : "Off")
                    InfoRow(label: "Time Sensitive", value: push.timeSensitiveEnabled == true ? "On" : "Off")
                } header: {
                    Text("Push")
                } footer: {
                    if let warning = PushWarning.text(model) {
                        Text(warning)
                    }
                }
                Section("More") {
                    Button("Notification settings") { openSettings() }
                    if let dashboard = dashboardURL {
                        Link("Open my dashboard", destination: dashboard)
                    }
                    Button("Unpair this phone", role: .destructive) { confirmUnpair = true }
                }
                Section {
                    EmptyView()
                } footer: {
                    Text("agentring \(AppInfo.version) · open source, Apache-2.0")
                        .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("Settings")
            .task { await push.refreshNotificationSettings() }
            .confirmationDialog("Unpair this phone", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair this phone", role: .destructive) { model.unpair() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Forget the pairing on this phone? To also revoke it on the relay run: agentring devices revoke \(model.pairing?.deviceId ?? "")")
            }
        }
    }

    /// The hosted service's dashboard (usage, plan), or nil for a self-hosted relay
    /// (same rule as Android's `Pairing.dashboardUrl`).
    private var dashboardURL: URL? {
        guard let p = model.pairing, let host = URL(string: p.relayUrl)?.host?.lowercased(), host == "agentring.io" else { return nil }
        return URL(string: "https://agentring.io/app#usage")
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline).textSelection(.enabled)
        }
    }
}
