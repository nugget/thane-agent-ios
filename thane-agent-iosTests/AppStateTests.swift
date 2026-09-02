import Foundation
import Testing
@testable import thane_agent_ios

@Suite("App state")
@MainActor
struct AppStateTests {
    @Test("App state owns global preferences and selects among agent profiles")
    func ownsGlobalPreferencesAndSelectsProfile() throws {
        let fixture = try AppStateFixture()
        defer { fixture.cleanup() }

        let preferences = AppPreferences(defaults: fixture.appDefaults)
        let appState = AppState(
            appPreferences: preferences,
            profiles: [fixture.configuredProfile, fixture.draftProfile],
            activeProfileID: fixture.draftProfile.id
        )

        #expect(appState.appPreferences === preferences)
        #expect(appState.profiles.map(\.id) == [
            fixture.configuredProfile.id,
            fixture.draftProfile.id,
        ])
        #expect(appState.activeProfile === fixture.draftProfile)
        #expect(appState.configuredProfiles.count == 1)
        #expect(appState.configuredProfiles.first === fixture.configuredProfile)

        fixture.draftProfile.connectionSettings.urlString = "https://second.example"

        #expect(appState.configuredProfiles.count == 2)
    }
}

@MainActor
private final class AppStateFixture {
    let appDefaults: UserDefaults
    let configuredProfile: AgentProfile
    let draftProfile: AgentProfile

    private let suites: [String]

    init() throws {
        let appSuite = "AppStateTests.app.\(UUID().uuidString)"
        let firstSuite = "AppStateTests.first.\(UUID().uuidString)"
        let secondSuite = "AppStateTests.second.\(UUID().uuidString)"
        suites = [appSuite, firstSuite, secondSuite]

        appDefaults = try #require(UserDefaults(suiteName: appSuite))
        let firstDefaults = try #require(UserDefaults(suiteName: firstSuite))
        let secondDefaults = try #require(UserDefaults(suiteName: secondSuite))

        configuredProfile = Self.makeProfile(defaults: firstDefaults)
        configuredProfile.connectionSettings.urlString = "https://first.example"
        draftProfile = Self.makeProfile(defaults: secondDefaults)
    }

    func cleanup() {
        configuredProfile.disconnect()
        draftProfile.disconnect()
        for suite in suites {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    private static func makeProfile(defaults: UserDefaults) -> AgentProfile {
        let credentialStore = AppStateCredentialStore()
        let settings = ConnectionSettings(
            defaults: defaults,
            credentialStore: credentialStore
        )
        return AgentProfile(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            identityPinning: IdentityPinningService(
                connectionID: settings.connectionID,
                secureStore: credentialStore
            )
        )
    }
}

@MainActor
private final class AppStateCredentialStore: CredentialStoring {
    func save(_ value: String, account: String) {}

    func load(account: String) -> String? {
        nil
    }

    func delete(account: String) {}
}
