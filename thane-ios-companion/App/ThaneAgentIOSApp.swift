import SwiftUI

/// Receives the one UIKit callback SwiftUI does not surface: the system
/// handing back a background URLSession whose events were delivered while
/// the app was not running. Without it, a transfer that completes during a
/// wake has nowhere to report, and iOS penalises an app that never calls
/// the completion handler it was given.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        let handler = UncheckedSendableBox(completionHandler)
        ObservationBackgroundSession.storeCompletionHandler(
            { handler.value() },
            for: identifier
        )
    }
}

/// UIKit hands this callback across an isolation boundary without a
/// `Sendable` annotation. It is called exactly once, on the main queue.
private nonisolated struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

@main
struct ThaneAgentIOSApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
