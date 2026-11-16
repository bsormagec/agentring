import SwiftUI
import UIKit

/// The thread with the agent: messages, read receipts, and the reply field.
struct MessagesView: View {
    let model: AppModel
    @State private var draft = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        let agent = model.pairing?.agentName ?? "agent"
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if model.messages.isEmpty {
                        ContentUnavailableView(
                            "No messages yet",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("When \(agent) writes to you, it shows up here. You can also write to it first.")
                        )
                        .padding(.top, 60)
                    }
                    LazyVStack(spacing: 8) {
                        ForEach(model.messages) { message in
                            Bubble(message: message, isLastOfMine: isLastOfMine(message))
                                .id(message.msgId)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .scrollDismissesKeyboard(.interactively)
                .onAppear { scrollToEnd(proxy, animated: false) }
                .onChange(of: model.messages.last?.msgId) { _, _ in scrollToEnd(proxy, animated: true) }
            }
            .safeAreaInset(edge: .bottom) { composer(agent: agent) }
            .navigationTitle(agent)
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            model.messagesVisible = true
            Task { await model.markAgentMessagesRead() }
        }
        .onDisappear { model.messagesVisible = false }
        .onChange(of: model.messages.count) { _, _ in
            if model.messagesVisible, model.isForeground { Task { await model.markAgentMessagesRead() } }
        }
    }

    private func composer(agent: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Text(error).font(.footnote).foregroundStyle(StatusColors.bad)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply to \(agent)", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                }
                .disabled(sending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        let text = draft
        sending = true
        error = nil
        Task {
            if let why = await model.send(text) {
                error = why
            } else {
                draft = ""
            }
            sending = false
        }
    }

    /// "Read" is shown under the user's last message once the agent read it.
    private func isLastOfMine(_ m: ThreadMessage) -> Bool {
        !m.fromAgent && model.messages.last(where: { !$0.fromAgent })?.msgId == m.msgId
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = model.messages.last?.msgId else { return }
        if animated {
            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

private struct Bubble: View {
    let message: ThreadMessage
    let isLastOfMine: Bool

    var body: some View {
        let mine = !message.fromAgent
        VStack(alignment: mine ? .trailing : .leading, spacing: 2) {
            Text(message.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(mine ? Color.white : Color.primary)
                .background(
                    mine ? Color.accentColor : Color(.secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            HStack(spacing: 4) {
                Text(Date(timeIntervalSince1970: Double(message.createdAt) / 1000), style: .time)
                if mine, isLastOfMine, message.readAt != nil {
                    Text("· Read")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 48)
    }
}
