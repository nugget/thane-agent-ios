import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Observation outbox")
struct ObservationOutboxTests {
    private let scope = ObservationDeliveryScope(
        connectionID: "connection-primary",
        identityID: "thane:ed25519:SHA256:primary"
    )

    @Test("Latest values coalesce by kind and survive reload")
    func coalescesAndReloads() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let first = try makeEvent(kind: .location, value: 1)
        let latest = try makeEvent(kind: .location, value: 2)
        let system = try makeEvent(kind: .systemContext, value: 3)

        try await outbox.enqueue(first, for: scope)
        try await outbox.enqueue(latest, for: scope)
        try await outbox.enqueue(system, for: scope)

        let pending = try await outbox.pending(for: scope)
        #expect(pending.count == 2)
        #expect(pending.first(where: { $0.kind == .location })?.eventID == latest.eventID)

        let restored = ObservationOutbox(fileURL: fixture.fileURL)
        let restoredPending = try await restored.pending(for: scope)
        #expect(restoredPending == pending)
    }

    @Test("Acknowledging an in-flight event does not remove its replacement")
    func acknowledgementPreservesReplacement() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let inFlight = try makeEvent(kind: .location, value: 1)
        let replacement = try makeEvent(kind: .location, value: 2)

        try await outbox.enqueue(inFlight, for: scope)
        try await outbox.enqueue(replacement, for: scope)
        try await outbox.removeSent(Set([inFlight.eventID]), for: scope)

        let pending = try await outbox.pending(for: scope)
        #expect(pending == [replacement])
    }

    @Test("Delayed older events cannot replace newer queued values")
    func delayedOlderEventIsIgnored() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let latest = try makeEvent(kind: .location, value: 2)
        let delayed = try makeEvent(kind: .location, value: 1)

        try await outbox.enqueue(latest, for: scope)
        try await outbox.enqueue(delayed, for: scope)

        #expect(try await outbox.pending(for: scope) == [latest])
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

        try await outbox.enqueue(available, for: scope)
        try await outbox.enqueue(withdrawal, for: scope)
        try await outbox.enqueue(available, for: scope)

        #expect(try await outbox.pending(for: scope) == [withdrawal])
    }

    @Test("A queue cannot be read or written under a different identity")
    func rejectsIdentityMismatch() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let event = try makeEvent(kind: .location, value: 1)

        try await outbox.enqueue(event, for: scope)

        let otherIdentity = ObservationDeliveryScope(
            connectionID: scope.connectionID,
            identityID: "thane:ed25519:SHA256:other"
        )
        let otherConnection = ObservationDeliveryScope(
            connectionID: "connection-other",
            identityID: scope.identityID
        )

        await #expect(throws: ObservationOutboxError.self) {
            _ = try await outbox.pending(for: otherIdentity)
        }
        await #expect(throws: ObservationOutboxError.self) {
            try await outbox.enqueue(event, for: otherConnection)
        }
    }

    @Test("Legacy unscoped observations are discarded rather than reassigned")
    func legacyMigrationFailsClosed() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let legacyEvent = try makeEvent(kind: .location, value: 1)
        let legacyData = try ObservationCoding.encoder().encode([legacyEvent])
        try legacyData.write(to: fixture.fileURL, options: .atomic)

        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let discardedCount = try await outbox.bind(to: scope)

        #expect(discardedCount == 1)
        #expect(try await outbox.pending(for: scope).isEmpty)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any]
        )
        #expect(object["connection_id"] as? String == scope.connectionID)
        #expect(object["identity_id"] as? String == scope.identityID)
        #expect((object["events"] as? [Any])?.isEmpty == true)
    }

    @Test("A legacy identity-scoped queue migrates into the matching connection profile")
    func identityScopedQueueMigration() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let event = try makeEvent(kind: .location, value: 1)
        let eventObject = try JSONSerialization.jsonObject(
            with: ObservationCoding.encoder().encode(event)
        )
        let legacyData = try JSONSerialization.data(withJSONObject: [
            "schema_version": 1,
            "identity_id": scope.identityID,
            "events": [eventObject],
        ])
        try legacyData.write(to: fixture.fileURL, options: .atomic)

        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let discardedCount = try await outbox.bind(to: scope)

        #expect(discardedCount == 0)
        #expect(try await outbox.pending(for: scope) == [event])
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.fileURL)) as? [String: Any]
        )
        #expect(object["schema_version"] as? Int == 2)
        #expect(object["connection_id"] as? String == scope.connectionID)
        #expect(object["identity_id"] as? String == scope.identityID)
    }

    @Test("Explicitly discarding a queue allows a new identity without carrying data forward")
    func discardAllowsIdentitySwitch() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        try await outbox.enqueue(try makeEvent(kind: .location, value: 1), for: scope)

        try await outbox.discardAll(for: scope)
        let newScope = ObservationDeliveryScope(
            connectionID: "connection-other",
            identityID: "thane:ed25519:SHA256:other"
        )
        try await outbox.enqueue(
            try makeEvent(kind: .systemContext, value: 2),
            for: newScope
        )

        let pending = try await outbox.pending(for: newScope)
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .systemContext)
    }

    @Test("Explicit discard removes an unreadable queue during identity recovery")
    func discardRemovesCorruptQueue() async throws {
        let fixture = try OutboxFixture()
        defer { fixture.cleanup() }
        try Data("not-json".utf8).write(to: fixture.fileURL, options: .atomic)
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)

        await #expect(throws: ObservationOutboxError.self) {
            _ = try await outbox.pending(for: scope)
        }

        try await outbox.discardAll()
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        try await outbox.enqueue(
            try makeEvent(kind: .location, value: 2),
            for: scope
        )
        #expect(try await outbox.pending(for: scope).count == 1)
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
