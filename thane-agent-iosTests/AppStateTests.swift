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

        let configured = fixture.makeProfile("profile-one")
        let draft = fixture.makeProfile("profile-two")
        configured.connectionSettings.urlString = "https://first.example"

        let preferences = AppPreferences(defaults: fixture.defaults)
        let appState = fixture.appState(
            profiles: [configured, draft],
            activeProfileID: draft.id,
            appPreferences: preferences
        )

        #expect(appState.appPreferences === preferences)
        #expect(appState.profiles.map(\.id) == ["profile-one", "profile-two"])
        #expect(appState.activeProfile === draft)
        #expect(appState.configuredProfiles.count == 1)
        #expect(appState.configuredProfiles.first === configured)

        draft.connectionSettings.urlString = "https://second.example"
        #expect(appState.configuredProfiles.count == 2)
    }

    @Test("A fresh installation resolves exactly one profile from the roster")
    func freshInstallationResolvesOneProfile() throws {
        let fixture = try AppStateFixture()
        defer { fixture.cleanup() }

        let appState = fixture.appState()

        #expect(appState.profiles.count == 1)
        #expect(appState.activeProfile === appState.profiles[0])
        #expect(
            fixture.defaults.array(forKey: AgentProfileRoster.rosterKey) as? [String]
                == [appState.activeProfile.id]
        )
    }

    @Test("Adding a profile mints an independent storage scope in the same suite")
    func addingProfileMintsIndependentScope() throws {
        let fixture = try AppStateFixture()
        defer { fixture.cleanup() }
        let appState = fixture.appState()
        let first = appState.activeProfile

        let second = appState.addProfile()

        #expect(appState.profiles.count == 2)
        #expect(second.id != first.id)
        #expect(second.connectionSettings.connectionID != first.connectionSettings.connectionID)
        #expect(second.connectionSettings.pairwiseClientID != first.connectionSettings.pairwiseClientID)
        #expect(
            second.connectionSettings.securityScope.tokenAccount
                != first.connectionSettings.securityScope.tokenAccount
        )
        #expect(
            fixture.defaults.array(forKey: AgentProfileRoster.rosterKey) as? [String]
                == [first.id, second.id]
        )

        // Independence must survive a relaunch against the same suite.
        let relaunched = fixture.appState()
        #expect(relaunched.profiles.map(\.id) == [first.id, second.id])
    }

    @Test("Removing a profile erases its scoped state and reselects an active profile")
    func removingProfileErasesScopedState() async throws {
        let fixture = try AppStateFixture()
        defer { fixture.cleanup() }
        let appState = fixture.appState()
        let first = appState.activeProfile
        let second = appState.addProfile()
        second.connectionSettings.urlString = "https://second.example"
        appState.selectProfile(second)
        let removedID = second.id

        let didRemove = await appState.removeProfile(second)

        #expect(didRemove)
        #expect(appState.profiles.map(\.id) == [first.id])
        #expect(appState.activeProfile === first)
        #expect(
            fixture.defaults.array(forKey: AgentProfileRoster.rosterKey) as? [String] == [first.id]
        )
        #expect(fixture.defaults.object(forKey: "agent.\(removedID).baseURL") == nil)
        #expect(fixture.defaults.object(forKey: "agent.\(removedID).configurationID") == nil)
        #expect(fixture.defaults.object(forKey: "agent.\(removedID).profileID") == nil)
    }

    @Test("Concurrent removals cannot empty the profile list")
    func concurrentRemovalsCannotEmptyProfiles() async throws {
        let fixture = try AppStateFixture()
        defer { fixture.cleanup() }
        let appState = fixture.appState()
        let first = appState.activeProfile
        let second = appState.addProfile()

        // Teardown suspends and @MainActor is reentrant, so both calls used to
        // pass a guard evaluated against the pre-removal count and then both
        // mutate — emptying the roster and trapping on profiles[0].
        async let removingFirst = appState.removeProfile(first)
        async let removingSecond = appState.removeProfile(second)
        let outcomes = await [removingFirst, removingSecond]

        #expect(outcomes.filter { $0 }.count == 1)
        #expect(appState.profiles.count == 1)
        #expect(appState.profiles.contains { $0 === appState.activeProfile })
        #expect(
            (fixture.defaults.array(forKey: AgentProfileRoster.rosterKey) as? [String])?.count == 1
        )
    }

    @Test("Removing the only profile is refused before any teardown begins")
    func removingLastProfileIsRefused() async throws {
        let fixture = try AppStateFixture()
        defer { fixture.cleanup() }
        let appState = fixture.appState()
        let only = appState.activeProfile
        only.connectionSettings.urlString = "https://only.example"
        let connectionID = only.connectionSettings.connectionID

        let didRemove = await appState.removeProfile(only)

        // Refusing must leave the profile completely intact — an earlier
        // ordering tore the connection down first and then reported refusal,
        // which erased the token, pin, inbox, and outbox anyway.
        #expect(didRemove == false)
        #expect(appState.profiles.count == 1)
        #expect(only.connectionSettings.urlString == "https://only.example")
        #expect(only.connectionSettings.connectionID == connectionID)
        #expect(
            fixture.defaults.string(forKey: "agent.\(only.id).configurationID") == connectionID
        )
    }
}

@MainActor
private final class AppStateFixture {
    let defaults: UserDefaults

    private let suite: String
    private let credentials = AppStateCredentialStore()

    init() throws {
        suite = "AppStateTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    /// Builds profiles wired to the fixture's suite and a fake Keychain, using
    /// the same profile-ID plumbing `AgentProfile.make` uses in production.
    func makeProfile(_ profileID: String) -> AgentProfile {
        let settings = ConnectionSettings(
            profileID: profileID,
            defaults: defaults,
            credentialStore: credentials
        )
        return AgentProfile(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            identityPinning: IdentityPinningService(
                connectionID: settings.connectionID,
                secureStore: credentials
            )
        )
    }

    func appState(
        profiles: [AgentProfile]? = nil,
        activeProfileID: String? = nil,
        appPreferences: AppPreferences? = nil
    ) -> AppState {
        AppState(
            appPreferences: appPreferences ?? AppPreferences(defaults: defaults),
            profiles: profiles,
            activeProfileID: activeProfileID,
            defaults: defaults,
            makeProfile: { [makeProfile] profileID, _ in makeProfile(profileID) }
        )
    }

    func cleanup() {
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}

@MainActor
private final class AppStateCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
    }
}
