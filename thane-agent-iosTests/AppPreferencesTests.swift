import Foundation
import Testing
@testable import thane_agent_ios

@Suite("App preferences")
@MainActor
struct AppPreferencesTests {
    @Test("Appearance defaults to the system setting")
    func defaultAppearance() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.appearance == .automatic)
    }

    @Test("Appearance persists independently of agent configuration")
    func appearancePersistence() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = AppPreferences(defaults: defaults)
        preferences.appearance = .dark

        let restored = AppPreferences(defaults: defaults)
        #expect(restored.appearance == .dark)
    }

    @Test("Unknown stored appearances fail back to automatic")
    func unknownAppearance() throws {
        let suite = "AppPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("future-value", forKey: "app.appearance")

        let preferences = AppPreferences(defaults: defaults)

        #expect(preferences.appearance == .automatic)
    }
}
