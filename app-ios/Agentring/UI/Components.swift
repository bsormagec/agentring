import SwiftUI
import UIKit

/// Small building blocks shared by the screens.

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }
}

struct StatusRow: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            StatusDot(color: color)
            Text(value)
        }
        .font(.subheadline)
    }
}

struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 56

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .foregroundStyle(.white)
    }
}

/// A numbered step of the pairing / "try it" instructions.
struct StepRow: View {
    let number: Int
    let title: String
    let detail: String
    var code: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .frame(width: 26, height: 26)
                .background(Color.accentColor.opacity(0.15), in: Circle())
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
                if let code {
                    HStack {
                        Text(code)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button {
                            UIPasteboard.general.string = code
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .accessibilityLabel("Copy")
                    }
                    .padding(10)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

enum StatusColors {
    static let ok = Color.green
    static let warn = Color.orange
    static let bad = Color.red
    static let idle = Color.gray
}

/// Why push can't wake this app, if it can't (pairing and settings screens).
@MainActor
enum PushWarning {
    static func text(_ model: AppModel) -> String? {
        guard let p = model.pairing else { return nil }
        guard let push = p.push, push.provider == "apns" else {
            return "Push notifications are not configured for iPhones on your relay, so messages and calls only arrive while the app is open. See app-ios/README.md."
        }
        if let topic = push.topic, topic != AppInfo.bundleId {
            return "This relay can't wake this app: it pushes to \(topic), but this app is \(AppInfo.bundleId). Messages and calls only arrive while the app is open."
        }
        switch model.push.state {
        case .error(let message):
            return "Push registration failed: \(message)"
        case .waitingForTokens where model.push.alertTokenError != nil:
            return "iOS didn't give this app a push token: \(model.push.alertTokenError ?? "")"
        default:
            return nil
        }
    }
}

extension PushState {
    var label: (String, Color) {
        switch self {
        case .registered: return ("Registered", StatusColors.ok)
        case .registering: return ("Registering…", StatusColors.warn)
        case .waitingForTokens: return ("Waiting for iOS…", StatusColors.warn)
        case .notConfigured: return ("Not configured on relay", StatusColors.warn)
        case .topicMismatch: return ("Relay can't reach this app", StatusColors.bad)
        case .error(let message): return ("Error: \(message)", StatusColors.bad)
        }
    }
}
