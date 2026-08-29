import SwiftUI

@main
struct ThaneAgentIOSApp: App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    appState.activate()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                appState.activate()
            case .background:
                appState.enterBackground()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
    }
}
