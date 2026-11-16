import SwiftUI

@main
struct AgentringApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: AppModel.shared)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: AppModel.shared.didBecomeActive()
            case .background: AppModel.shared.didEnterBackground()
            default: break
            }
        }
    }
}
