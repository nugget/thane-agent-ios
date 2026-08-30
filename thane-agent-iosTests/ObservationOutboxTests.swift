import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Observation outbox")
struct ObservationOutboxTests {
    @Test("Latest values coalesce by kind and survive reload")
    func coalescesAndReloads() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let first = try makeEvent(kind: .location, value: 1)
        let latest = try makeEvent(kind: .location, value: 2)
        let system = try makeEvent(kind: .systemContext, value: 3)

        try await outbox.enqueue(first)
        try await outbox.enqueue(latest)
        try await outbox.enqueue(system)

        let pending = try await outbox.pending()
        #expect(pending.count == 2)
        #expect(pending.first(where: { $0.kind == .location })?.eventID == latest.eventID)

        let restored = ObservationOutbox(fileURL: fixture.fileURL)
        let restoredPending = try await restored.pending()
        #expect(restoredPending == pending)
    }

    @Test("Acknowledging an in-flight event does not remove its replacement")
    func acknowledgementPreservesReplacement() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let inFlight = try makeEvent(kind: .location, value: 1)
        let replacement = try makeEvent(kind: .location, value: 2)

        try await outbox.enqueue(inFlight)
        try await outbox.enqueue(replacement)
        try await outbox.removeSent(Set([inFlight.eventID]))

        let pending = try await outbox.pending()
        #expect(pending == [replacement])
    }

    @Test("Delayed older events cannot replace newer queued values")
    func delayedOlderEventIsIgnored() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let latest = try makeEvent(kind: .location, value: 2)
        let delayed = try makeEvent(kind: .location, value: 1)

        try await outbox.enqueue(latest)
        try await outbox.enqueue(delayed)

        #expect(try await outbox.pending() == [latest])
    }

    @Test("Withdrawal wins at an equal observation time")
    func equalTimeWithdrawalDominates() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let observedAt = Date(timeIntervalSince1970: 2)
        let withdrawal = ObservationEvent(
            eventID: try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111")),
            kind: .location,
            schemaVersion: 1,
            status: .withdrawn,
            observedAt: observedAt,
            payload: nil
        )
        let available = ObservationEvent(
            eventID: try #require(UUID(uuidString: "FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")),
            kind: .location,
            schemaVersion: 1,
            status: .available,
            observedAt: observedAt,
            payload: try AnyCodable.fromEncodable(TestPayload(value: 2))
        )

        try await outbox.enqueue(available)
        try await outbox.enqueue(withdrawal)
        try await outbox.enqueue(available)

        #expect(try await outbox.pending() == [withdrawal])
    }

    @Test("Withdrawal tombstones omit sensitive payloads")
    func withdrawalOmitsPayload() throws {
        let event = ObservationEvent.withdrawn(kind: .location)
        let data = try ObservationCoding.encoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["status"] as? String == "withdrawn")
        #expect(object["payload"] == nil)
    }

    @Test("Wire timestamps preserve subsecond ordering")
    func timestampEncodingPreservesSubseconds() throws {
        let observedAt = Date(timeIntervalSince1970: 1_777_777_777.123)
        let event = try ObservationEvent.available(
            kind: .location,
            observedAt: observedAt,
            payload: TestPayload(value: 1)
        )

        let data = try ObservationCoding.encoder().encode(event)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try #require(object["observed_at"] as? String)
        #expect(encoded.contains(".123"))

        let decoded = try ObservationCoding.decoder().decode(ObservationEvent.self, from: data)
        #expect(abs(decoded.observedAt.timeIntervalSince(observedAt)) < 0.001)
    }

    private func makeEvent(kind: ObservationKind, value: Int) throws -> ObservationEvent {
        try ObservationEvent.available(
            kind: kind,
            observedAt: Date(timeIntervalSince1970: TimeInterval(value)),
            payload: TestPayload(value: value)
        )
    }
}

private struct TestPayload: Codable, Sendable {
    let value: Int
}

private final class OutboxFixture: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObservationOutboxTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("outbox.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
