import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Connection settings")
@MainActor
struct ConnectionSettingsTests {
    @Test("Forget Token deletes the Keychain value, clears the field, and disconnects")
    func forgetToken() throws {
        let suite = "ConnectionSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FakeCredentialStore(value: "secret")
        let settings = ConnectionSettings(
            defaults: defaults,
            credentialStore: credentials
        )
        settings.isEnabled = true
        let preferences = SharingPreferences(defaults: defaults)
        let appState = AppState(
            connectionSettings: settings,
            sharingPreferences: preferences,
            identityPinning: IdentityPinningService(
                secureStore: FakeCredentialStore(value: nil)
            )
        )

        #expect(appState.tokenInput == "secret")

        appState.forgetToken()

        #expect(credentials.value == nil)
        #expect(credentials.deletedAccounts == ["thane-api-token"])
        #expect(appState.tokenInput.isEmpty)
        #expect(settings.isEnabled == false)
        #expect(appState.connection.state == .disconnected)
    }
}

@MainActor
private final class FakeCredentialStore: CredentialStoring {
    var value: String?
    private(set) var deletedAccounts: [String] = []

    init(value: String?) {
        self.value = value
    }

    func save(_ value: String, account: String) {
        self.value = value
    }

    func load(account: String) -> String? {
        value
    }

    func delete(account: String) {
        value = nil
        deletedAccounts.append(account)
    }
}
