import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Observation transport")
struct ObservationTransportTests {
    @Test("Request matches the companion observation contract")
    func requestContract() throws {
        let batch = try makeBatch()
        let request = try URLSessionObservationUploader.request(
            for: batch,
            baseURL: try #require(URL(string: "https://thane.example/base")),
            token: "secret-token"
        )

        #expect(request.url?.absoluteString == "https://thane.example/base/v1/companion/observations")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")

        let body = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["client_id"] as? String == "client-id")
        #expect(object["client_name"] as? String == "Thane for iOS")
        #expect(object["platform"] as? String == "ios")
        #expect(object["app_version"] as? String == "0.1.0 (1)")
        #expect(object["os_version"] as? String == "26.6")

        let events = try #require(object["events"] as? [[String: Any]])
        let event = try #require(events.first)
        #expect(event["event_id"] as? String == "11111111-1111-4111-8111-111111111111")
        #expect(event["kind"] as? String == "ios.location")
        #expect(event["schema_version"] as? Int == 1)
        #expect(event["status"] as? String == "available")
        #expect(event["observed_at"] as? String == "2026-08-30T16:59:55.123Z")
        let payload = try #require(event["payload"] as? [String: Any])
        #expect(payload["horizontal_accuracy_meters"] as? Double == 12)
    }

    @Test("Accepted response decodes server receipt details")
    func acceptedResponse() throws {
        let url = try #require(URL(string: "https://thane.example/v1/companion/observations"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 202,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let data = Data(#"{"stored":1,"ignored":0,"received_at":"2026-08-30T17:00:00Z"}"#.utf8)

        let result = try URLSessionObservationUploader.result(from: data, response: response)

        #expect(result.stored == 1)
        #expect(result.ignored == 0)
        #expect(result.receivedAt == ObservationCoding.date(from: "2026-08-30T17:00:00Z"))
    }

    @Test("Structured rejection remains operator-readable")
    func rejectedResponse() throws {
        let url = try #require(URL(string: "https://thane.example/v1/companion/observations"))
        let response = try #require(HTTPURLResponse(
            url: url,
            statusCode: 401,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
        let data = Data(#"{"error":{"code":"unauthorized","message":"a valid companion bearer token is required"}}"#.utf8)

        do {
            _ = try URLSessionObservationUploader.result(from: data, response: response)
            Issue.record("Expected the observation upload to be rejected")
        } catch let error as ObservationUploadError {
            #expect(
                error.localizedDescription
                    == "Thane rejected observations (HTTP 401): a valid companion bearer token is required"
            )
        }
    }

    @Test("Background session identifiers are scoped per profile")
    func sessionIdentifierIsProfileScoped() {
        let first = URLSessionObservationUploader.sessionIdentifier(profileID: "profile-a")
        let second = URLSessionObservationUploader.sessionIdentifier(profileID: "profile-b")

        #expect(first != second)
        #expect(first.hasPrefix("info.nugget.thane-ios-companion.observations."))
        #expect(first.hasSuffix("profile-a"))
    }

    @Test("The upload body is written to a file the session can read after this process")
    func bodyIsWrittenToFile() throws {
        let batch = try makeBatch()
        let body = try ObservationCoding.encoder().encode(batch)
        let fileURL = try URLSessionObservationUploader.writeBody(body)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        // A background upload task refuses an in-memory body; the file is
        // what lets the transfer outlive the app.
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        let written = try Data(contentsOf: fileURL)
        #expect(written == body)

        let object = try #require(JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["client_id"] as? String == "client-id")
    }

    private func makeBatch() throws -> ObservationBatch {
        let payload = try AnyCodable.fromEncodable([
            "latitude": 41.8819,
            "longitude": -87.6278,
            "horizontal_accuracy_meters": 12,
        ])
        let event = ObservationEvent(
            eventID: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            kind: .location,
            schemaVersion: 1,
            status: .available,
            observedAt: try #require(ObservationCoding.date(from: "2026-08-30T16:59:55.123Z")),
            payload: payload
        )
        return ObservationBatch(
            clientID: "client-id",
            clientName: "Thane for iOS",
            platform: "ios",
            appVersion: "0.1.0 (1)",
            osVersion: "26.6",
            events: [event]
        )
    }
}
