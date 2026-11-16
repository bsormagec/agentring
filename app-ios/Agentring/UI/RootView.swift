import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if model.pairing == nil {
                if model.pairingLocked {
                    LockedView()
                } else {
                    OnboardingFlow(model: model)
                }
            } else if !model.setupComplete {
                PairedView(model: model)
            } else {
                MainTabs(model: model)
            }
        }
        .fullScreenCover(isPresented: callScreenShown) {
            CallView(calls: model.calls)
        }
    }

    /// The call screen is up while there is a call (and briefly after it ends).
    private var callScreenShown: Binding<Bool> {
        Binding(get: { model.calls.state != nil }, set: { _ in })
    }
}

/// Launched before the first unlock after a reboot: the Keychain is still closed.
private struct LockedView: View {
    var body: some View {
        ContentUnavailableView(
            "Unlock your iPhone",
            systemImage: "lock",
            description: Text("agentring can read its pairing once the phone has been unlocked.")
        )
    }
}

struct MainTabs: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            HomeView(model: model)
                .tabItem { Label("Home", systemImage: "house") }
                .tag(AppTab.home)
            MessagesView(model: model)
                .tabItem { Label("Messages", systemImage: "bubble.left.and.bubble.right") }
                .tag(AppTab.messages)
                .badge(model.messages.filter { $0.fromAgent && $0.readAt == nil }.count)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
