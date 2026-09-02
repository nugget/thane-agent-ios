import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState
    @State private var router = AppRouter()

    var body: some View {
        @Bindable var router = router

        TabView(selection: $router.selectedSection) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: .chats) {
                NavigationStack(path: $router.chatPath) {
                    ChatView {
                        router.showSettings()
                    }
                    .navigationDestination(for: AppDestination.self) { destination in
                        AppDestinationView(
                            profile: appState.activeProfile,
                            destination: destination,
                            openSettings: router.showSettings
                        )
                    }
                }
            }

            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .preferredColorScheme(preferredColorScheme)
        .onOpenURL { url in
            router.open(
                url,
                activeCounterparty: appState.activeProfile.counterparty
            )
        }
        .onChange(of: appState.activeProfile.counterparty?.id) { _, counterpartyID in
            router.reconcile(activeCounterpartyID: counterpartyID)
        }
        .sheet(item: $router.issue) { issue in
            RouteIssueView(issue: issue)
        }
    }

    private var preferredColorScheme: ColorScheme? {
        switch appState.appPreferences.appearance {
        case .automatic: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

#if DEBUG
#Preview {
    RootView()
        .environment(PreviewFixtures.appState())
}
#endif
