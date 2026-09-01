import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Server connection")
@MainActor
struct ServerConnectionTests {
    @Test("Connection establishment flushes registered follow-up work")
    func connectionEstablishedCallback() {
        let connection = ServerConnection()
        var callbackCount = 0
        connection.onConnected = {
            callbackCount += 1
        }

        connection.handleConnectionEstablished()

        #expect(connection.state == .connected)
        #expect(connection.lastError == nil)
        #expect(callbackCount == 1)
    }

    @Test("Authentication failure stops reconnecting and reports the error")
    func authenticationFailureIsTerminal() {
        let connection = ServerConnection()
        var callbackCount = 0
        connection.onAuthenticationFailure = {
            callbackCount += 1
        }

        connection.handleAuthenticationFailure("Invalid token")

        #expect(connection.state == .disconnected)
        #expect(connection.lastError == "Authentication failed: Invalid token")
        #expect(callbackCount == 1)
    }

    @Test("Authentication failure disables persisted auto-connect")
    func authenticationFailureDisablesAutoConnect() throws {
        let suite = "ServerConnectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ConnectionSettings(
            defaults: defaults,
            credentialStore: AuthenticationCredentialStore()
        )
        settings.isEnabled = true
        let appState = AppState(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            identityPinning: IdentityPinningService(
                connectionID: settings.connectionID,
                secureStore: AuthenticationCredentialStore()
            )
        )

        appState.connection.handleAuthenticationFailure("Expired token")

        #expect(settings.isEnabled == false)
        #expect(appState.connection.state == .disconnected)
        #expect(appState.displayedError == "Authentication failed: Expired token")
    }
}

@MainActor
private final class AuthenticationCredentialStore: CredentialStoring {
    func save(_ value: String, account: String) {}

    func load(account: String) -> String? {
        nil
    }

    func delete(account: String) {}
}
