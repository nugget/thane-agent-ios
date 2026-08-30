import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Sharing preferences")
@MainActor
struct SharingPreferencesTests {
    @Test("Every data source defaults off")
    func defaultsOff() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SharingPreferences(defaults: defaults)

        #expect(preferences.enabledSystemCategories.isEmpty)
        #expect(preferences.locationEnabled == false)
        #expect(preferences.backgroundLocationEnabled == false)
        #expect(preferences.hasEnabledData == false)
    }

    @Test("Choices persist independently")
    func persistence() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SharingPreferences(defaults: defaults)
        preferences.setEnabled(true, for: .regional)
        preferences.locationEnabled = true
        preferences.backgroundLocationEnabled = true

        let restored = SharingPreferences(defaults: defaults)
        #expect(restored.regionalEnabled)
        #expect(restored.locationEnabled)
        #expect(restored.backgroundLocationEnabled)
        #expect(restored.deviceEnabled == false)
        #expect(restored.networkEnabled == false)
    }

    @Test("Background location cannot restore without its parent location source")
    func invalidBackgroundLocationStateIsNormalized() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SharingPreferences(defaults: defaults)
        preferences.backgroundLocationEnabled = true

        let restored = SharingPreferences(defaults: defaults)
        #expect(restored.backgroundLocationEnabled == false)
        #expect(restored.hasEnabledData == false)
    }
}
