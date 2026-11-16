import SwiftUI
import UIKit

struct HomeView: View {
    let model: AppModel
    @State private var placing = false
    @State private var error: String?

    var body: some View {
        let connection = model.connection
        let calls = model.calls
        let agent = model.pairing?.agentName ?? "agent"
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if model.revoked {
                        Card {
                            Text("This phone was unpaired").font(.headline)
                            Text("The relay no longer accepts this phone. Pair it again with agentring pair.")
                                .font(.subheadline)
                            Button("Pair again") { model.unpair() }.buttonStyle(.borderedProminent)
                        }
                    }
                    if let offer = calls.joinOffer {
                        JoinCard(offer: offer) {
                            Task { await calls.join(offer) }
                        }
                    }
                    callCard(agent: agent, connection: connection, calls: calls)
                    Card {
                        Text("Connection").font(.headline)
                        relayRow(connection)
                        agentRow(connection)
                        let push = model.push.state.label
                        StatusRow(label: "Push", value: push.0, color: push.1)
                        if let warning = PushWarning.text(model) {
                            Text(warning).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("agentring")
            .refreshable {
                connection.reconnect()
            }
        }
    }

    private func callCard(agent: String, connection: ConnectionManager, calls: CallController) -> some View {
        let canCall = connection.isConnected && connection.agentOnline == true && calls.isIdle && !model.revoked
        let hint: String = {
            if let error { return error }
            if placing { return Strings.calling(agent) }
            if !connection.isConnected { return Strings.needsRelay }
            if connection.agentOnline != true { return Strings.agentOffline }
            if !calls.isIdle { return Strings.inCall }
            return "Talk to \(agent) by voice."
        }()
        return Card {
            HStack(spacing: 14) {
                AgentAvatar(name: agent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(agent).font(.title2.bold())
                    HStack(spacing: 6) {
                        let status = presence(connection)
                        StatusDot(color: status.1)
                        Text(status.0).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                placeCall()
            } label: {
                Label("Call \(agent)", systemImage: "phone.fill")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canCall || placing)
            .opacity(canCall && !placing ? 1 : 0.5)
            Text(hint)
                .font(.footnote)
                .foregroundStyle(error == nil ? Color.secondary : StatusColors.bad)
        }
    }

    private func placeCall() {
        guard !placing else { return }
        placing = true
        error = nil
        Task {
            error = await model.calls.callAgent()
            placing = false
        }
    }

    private func presence(_ c: ConnectionManager) -> (String, Color) {
        switch c.agentOnline {
        case true?: return ("Online", StatusColors.ok)
        case false?: return ("Offline", StatusColors.idle)
        case nil: return ("Checking…", StatusColors.idle)
        }
    }

    private func relayRow(_ c: ConnectionManager) -> some View {
        let (text, color): (String, Color) = {
            switch c.relayState {
            case .connected: return ("Connected", StatusColors.ok)
            case .connecting: return ("Connecting…", StatusColors.warn)
            case .disconnected: return ("Offline", StatusColors.bad)
            }
        }()
        return StatusRow(label: "Relay", value: text, color: color)
    }

    private func agentRow(_ c: ConnectionManager) -> some View {
        let (text, color): (String, Color) = {
            switch c.agentOnline {
            case true?: return ("Online", StatusColors.ok)
            case false?: return ("Offline", StatusColors.bad)
            case nil: return ("Unknown", StatusColors.idle)
            }
        }()
        return StatusRow(label: "Agent", value: text, color: color)
    }
}

private struct JoinCard: View {
    let offer: JoinOffer
    let join: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "phone.connection.fill")
                    .font(.title2)
                    .foregroundStyle(StatusColors.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Strings.inProgressWith(offer.info.agentName)).font(.headline)
                    Text(offer.info.reason.isEmpty ? Strings.joinHint : offer.info.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button(Strings.join, action: join)
                    .buttonStyle(.borderedProminent)
                    .tint(StatusColors.ok)
            }
        }
    }
}
