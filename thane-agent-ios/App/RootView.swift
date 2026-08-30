import SwiftUI

private enum AppSection: Hashable {
    case thane
    case context
    case settings
}

struct RootView: View {
    @State private var selection: AppSection = .thane

    var body: some View {
        TabView(selection: $selection) {
            Tab("Thane", systemImage: "point.3.connected.trianglepath.dotted", value: .thane) {
                NavigationStack {
                    ThaneHomeView {
                        selection = .settings
                    }
                }
            }

            Tab("Context", systemImage: "sensor.tag.radiowaves.forward", value: .context) {
                NavigationStack {
                    ContextView()
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
