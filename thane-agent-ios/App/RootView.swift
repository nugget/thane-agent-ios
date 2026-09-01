import SwiftUI

private enum AppSection: Hashable {
    case chats
    case settings
}

struct RootView: View {
    @State private var selection: AppSection = .chats

    var body: some View {
        TabView(selection: $selection) {
            Tab("Chats", systemImage: "bubble.left.and.bubble.right", value: .chats) {
                NavigationStack {
                    ChatView {
                        selection = .settings
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
    }
}

#Preview {
    RootView()
        .environment(AppState())
}
