import Foundation
import Testing
@testable import thane_agent_ios

@Suite("iOS system context")
@MainActor
struct SystemContextTests {
    @Test("Disabled context fails without reading data")
    func disabled() throws {
        let suite = "SystemContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SystemContextService(
            preferences: SharingPreferences(defaults: defaults)
        )

        #expect(throws: SystemContextServiceError.self) {
            try service.snapshot()
        }
    }

    @Test("Only enabled categories are encoded")
    func categoryOmission() throws {
        let suite = "SystemContextTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = SharingPreferences(defaults: defaults)
        preferences.regionalEnabled = true
        let service = SystemContextService(preferences: preferences)

        let snapshot = try service.snapshot(at: Date(timeIntervalSince1970: 0))
        #expect(snapshot.capturedAt == "1970-01-01T00:00:00Z")
        #expect(snapshot.regional != nil)
        #expect(snapshot.device == nil)
        #expect(snapshot.network == nil)

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["regional"] != nil)
        #expect(object["device"] == nil)
        #expect(object["network"] == nil)
    }
}
