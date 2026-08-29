import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Location snapshot")
struct LocationSnapshotTests {
    @Test("Location fields use stable snake-case wire names")
    func encoding() throws {
        let snapshot = LocationSnapshot(
            capturedAt: "2026-08-29T12:00:00Z",
            locationTimestamp: "2026-08-29T11:59:59Z",
            latitude: 41.88,
            longitude: -87.63,
            altitudeMeters: 181,
            ellipsoidalAltitudeMeters: 149,
            horizontalAccuracyMeters: 5,
            verticalAccuracyMeters: nil,
            speedMetersPerSecond: nil,
            speedAccuracyMetersPerSecond: nil,
            courseDegrees: nil,
            courseAccuracyDegrees: nil,
            floor: nil,
            authorization: "when_in_use",
            accuracyAuthorization: "full",
            simulatedBySoftware: false,
            producedByAccessory: false
        )

        let data = try JSONEncoder().encode(snapshot)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(object["horizontal_accuracy_meters"] as? Double == 5)
        #expect(object["accuracy_authorization"] as? String == "full")
        #expect(object["vertical_accuracy_meters"] == nil)
        #expect(object["simulated_by_software"] as? Bool == false)
    }
}
