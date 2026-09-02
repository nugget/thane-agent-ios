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
        preferences.scope(to: "thane:one")

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
        preferences.scope(to: "thane:one")
        preferences.setEnabled(true, for: .regional)
        preferences.locationEnabled = true
        preferences.backgroundLocationEnabled = true

        let restored = SharingPreferences(defaults: defaults)
        restored.scope(to: "thane:one")
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
        preferences.scope(to: "thane:one")
        preferences.backgroundLocationEnabled = true

        let restored = SharingPreferences(defaults: defaults)
        restored.scope(to: "thane:one")
        #expect(restored.backgroundLocationEnabled == false)
        #expect(restored.hasEnabledData == false)

        restored.locationEnabled = true
        restored.scope(to: nil)
        restored.scope(to: "thane:one")
        #expect(restored.locationEnabled)
        #expect(restored.backgroundLocationEnabled == false)
    }

    @Test("Choices are isolated by stable counterparty identity")
    func counterpartyIsolation() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: "thane:one")
        preferences.deviceEnabled = true
        preferences.locationEnabled = true

        preferences.scope(to: "thane:two")
        #expect(preferences.hasEnabledData == false)

        preferences.networkEnabled = true
        preferences.scope(to: "thane:one")
        #expect(preferences.deviceEnabled)
        #expect(preferences.locationEnabled)
        #expect(preferences.networkEnabled == false)

        preferences.scope(to: "thane:two")
        #expect(preferences.deviceEnabled == false)
        #expect(preferences.locationEnabled == false)
        #expect(preferences.networkEnabled)
    }

    @Test("Legacy single-connection choices migrate to the first pinned identity only")
    func legacyMigration() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sharing.regional")
        defaults.set(true, forKey: "sharing.location")

        let preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: "thane:one")
        #expect(preferences.regionalEnabled)
        #expect(preferences.locationEnabled)

        preferences.scope(to: "thane:two")
        #expect(preferences.hasEnabledData == false)
        #expect(defaults.object(forKey: "sharing.regional") == nil)
        #expect(defaults.object(forKey: "sharing.location") == nil)
    }

    @Test("Unattributed legacy choices are discarded before a new identity is pinned")
    func unattributedLegacyChoicesAreDiscarded() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "sharing.regional")
        defaults.set(true, forKey: "sharing.location")

        let preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: nil)
        preferences.scope(to: "thane:new")

        #expect(preferences.hasEnabledData == false)
        #expect(defaults.object(forKey: "sharing.regional") == nil)
        #expect(defaults.object(forKey: "sharing.location") == nil)
    }

    @Test("An absent identity always presents an all-off policy")
    func absentIdentityIsAllOff() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: "thane:one")
        preferences.regionalEnabled = true

        preferences.scope(to: nil)
        #expect(preferences.counterpartyID == nil)
        #expect(preferences.hasEnabledData == false)

        preferences.regionalEnabled = true
        let restored = SharingPreferences(defaults: defaults)
        #expect(restored.hasEnabledData == false)
    }

    @Test("Removing a counterparty deletes only its sharing policy")
    func removeCounterpartyPolicy() throws {
        let suite = "SharingPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: "thane:one")
        preferences.regionalEnabled = true
        preferences.scope(to: "thane:two")
        preferences.networkEnabled = true

        preferences.removeScope(for: "thane:one")
        preferences.scope(to: "thane:one")
        #expect(preferences.hasEnabledData == false)

        preferences.scope(to: "thane:two")
        #expect(preferences.networkEnabled)
    }
}
