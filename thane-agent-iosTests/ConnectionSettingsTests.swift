import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Connection settings")
@MainActor
struct ConnectionSettingsTests {
    @Test("Pairwise client identity is durable, counterparty-bound, and rotated on rebind")
    func pairwiseClientIdentity() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }

        let settings = ConnectionSettings(
            defaults: fixture.defaults,
            credentialStore: fixture.credentials
        )
        let connectionID = settings.connectionID
        let clientID = settings.pairwiseClientID

        #expect(!settings.bindPairwiseClientID(to: "thane:identity:first"))
        #expect(settings.pairwiseClientID == clientID)

        let restored = ConnectionSettings(
            defaults: fixture.defaults,
            credentialStore: fixture.credentials
        )
        #expect(restored.connectionID == connectionID)
        #expect(restored.pairwiseClientID == clientID)
        #expect(restored.pairwiseCounterpartyID == "thane:identity:first")
        #expect(!restored.bindPairwiseClientID(to: "thane:identity:first"))

        #expect(restored.bindPairwiseClientID(to: "thane:identity:second"))
        #expect(restored.connectionID == connectionID)
        #expect(restored.pairwiseClientID != clientID)
        #expect(restored.pairwiseCounterpartyID == "thane:identity:second")
    }

    @Test("Independent connection profiles never reuse a pairwise client identity")
    func independentProfilesUseDistinctIdentities() throws {
        let first = try SettingsFixture()
        let second = try SettingsFixture(credentials: first.credentials)
        defer {
            first.cleanup()
            second.cleanup()
        }

        let firstSettings = ConnectionSettings(
            defaults: first.defaults,
            credentialStore: first.credentials
        )
        let secondSettings = ConnectionSettings(
            defaults: second.defaults,
            credentialStore: second.credentials
        )
        firstSettings.bindPairwiseClientID(to: "thane:identity:first")
        secondSettings.bindPairwiseClientID(to: "thane:identity:second")
        try firstSettings.saveToken("first-token")
        try secondSettings.saveToken("second-token")

        #expect(firstSettings.connectionID != secondSettings.connectionID)
        #expect(firstSettings.pairwiseClientID != secondSettings.pairwiseClientID)
        #expect(
            first.credentials.value(account: firstSettings.securityScope.tokenAccount)
                == "first-token"
        )
        #expect(
            first.credentials.value(account: secondSettings.securityScope.tokenAccount)
                == "second-token"
        )
    }

    @Test("Removing a profile rotates both local and pairwise identities")
    func removalRotatesIdentities() throws {
        let fixture = try SettingsFixture()
        defer { fixture.cleanup() }
        let settings = ConnectionSettings(
            defaults: fixture.defaults,
            credentialStore: fixture.credentials
        )
        settings.bindPairwiseClientID(to: "thane:identity:first")
        let connectionID = settings.connectionID
        let clientID = settings.pairwiseClientID

        settings.removeConfiguration()

        #expect(settings.connectionID != connectionID)
        #expect(settings.pairwiseClientID != clientID)
        #expect(settings.pairwiseCounterpartyID == nil)
    }

    @Test("Legacy client identity and token migrate into the current connection profile")
    func legacyMigration() throws {
        let credentials = FakeCredentialStore(
            values: [ConnectionSecurityScope.legacyTokenAccount: "secret"]
        )
        let fixture = try SettingsFixture(credentials: credentials)
        defer { fixture.cleanup() }
        fixture.defaults.set("connection-one", forKey: "connection.configurationID")
        fixture.defaults.set("legacy-client", forKey: "connection.clientID")

        let settings = ConnectionSettings(
            defaults: fixture.defaults,
            credentialStore: credentials
        )

        #expect(settings.pairwiseClientID == "legacy-client")
        #expect(try settings.storedToken() == "secret")
        #expect(credentials.value(account: settings.securityScope.tokenAccount) == "secret")
        #expect(credentials.value(account: ConnectionSecurityScope.legacyTokenAccount) == nil)
        #expect(fixture.defaults.object(forKey: "connection.clientID") == nil)

        let restored = ConnectionSettings(
            defaults: fixture.defaults,
            credentialStore: credentials
        )
        #expect(restored.pairwiseClientID == "legacy-client")
    }

    @Test("Forget Token deletes the connection-scoped Keychain value, clears the field, and disconnects")
    func forgetToken() throws {
        let credentials = FakeCredentialStore(
            values: [ConnectionSecurityScope.legacyTokenAccount: "secret"]
        )
        let fixture = try SettingsFixture(credentials: credentials)
        defer { fixture.cleanup() }
        let settings = ConnectionSettings(
            defaults: fixture.defaults,
            credentialStore: credentials
        )
        settings.isEnabled = true
        let preferences = SharingPreferences(defaults: fixture.defaults)
        let profile = AgentProfile(
            connectionSettings: settings,
            sharingPreferences: preferences,
            identityPinning: IdentityPinningService(
                connectionID: settings.connectionID,
                secureStore: FakeCredentialStore()
            )
        )

        #expect(profile.tokenInput == "secret")
        #expect(credentials.value(account: settings.securityScope.tokenAccount) == "secret")

        profile.forgetToken()

        #expect(credentials.value(account: settings.securityScope.tokenAccount) == nil)
        #expect(credentials.value(account: ConnectionSecurityScope.legacyTokenAccount) == nil)
        #expect(profile.tokenInput.isEmpty)
        #expect(settings.isEnabled == false)
        #expect(profile.connection.state == .disconnected)
    }
}

@MainActor
private final class FakeCredentialStore: CredentialStoring {
    private var values: [String: String]

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
    }

    func value(account: String) -> String? {
        values[account]
    }
}

@MainActor
private final class SettingsFixture {
    let suite: String
    let defaults: UserDefaults
    let credentials: FakeCredentialStore

    init(credentials: FakeCredentialStore = FakeCredentialStore()) throws {
        suite = "ConnectionSettingsTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        self.credentials = credentials
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}
