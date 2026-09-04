import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Observation publisher")
@MainActor
struct ObservationPublisherTests {
    @Test("A flush requested during a failed upload runs once afterward")
    func deferredFlushAfterFailure() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let identityID = "thane:ed25519:SHA256:primary"
        let deliveryScope = ObservationDeliveryScope(
            connectionID: "connection-primary",
            identityID: identityID
        )
        try await outbox.enqueue(try ObservationEvent.available(
            kind: .systemContext,
            observedAt: Date(),
            payload: PublisherTestPayload(value: 1)
        ), for: deliveryScope)
        let uploader = SequencedObservationUploader()
        let publisher = ObservationPublisher(outbox: outbox, uploader: uploader)
        let baseURL = try #require(URL(string: "https://thane.example"))

        publisher.configure(
            baseURL: baseURL,
            token: "token",
            clientID: "client-id",
            deliveryScope: deliveryScope,
            authorizationExpiresAt: .distantFuture
        )
        try await waitUntil { uploader.callCount == 1 }

        publisher.flush()
        uploader.failFirstUpload()

        try await waitUntil { uploader.callCount == 2 }
        try await waitUntil { publisher.pendingCount == 0 && !publisher.isUploading }
        #expect(try await outbox.pending(for: deliveryScope).isEmpty)
        #expect(uploader.callCount == 2)
    }

    @Test("Changing a verified destination restarts delivery without stranding the scoped queue")
    func destinationChangeRestartsDelivery() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let identityID = "thane:ed25519:SHA256:primary"
        let deliveryScope = ObservationDeliveryScope(
            connectionID: "connection-primary",
            identityID: identityID
        )
        try await outbox.enqueue(try ObservationEvent.available(
            kind: .location,
            observedAt: Date(),
            payload: PublisherTestPayload(value: 1)
        ), for: deliveryScope)
        let uploader = SequencedObservationUploader()
        let publisher = ObservationPublisher(outbox: outbox, uploader: uploader)
        let firstURL = try #require(URL(string: "https://first.example"))
        let secondURL = try #require(URL(string: "https://second.example"))

        publisher.configure(
            baseURL: firstURL,
            token: "first-token",
            clientID: "client-id",
            deliveryScope: deliveryScope,
            authorizationExpiresAt: .distantFuture
        )
        try await waitUntil { uploader.callCount == 1 }

        publisher.configure(
            baseURL: nil,
            token: nil,
            clientID: "",
            deliveryScope: nil,
            authorizationExpiresAt: nil
        )
        publisher.configure(
            baseURL: secondURL,
            token: "second-token",
            clientID: "client-id",
            deliveryScope: deliveryScope,
            authorizationExpiresAt: .distantFuture
        )

        try await waitUntil { uploader.callCount == 2 }
        try await waitUntil { publisher.pendingCount == 0 && !publisher.isUploading }
        uploader.failFirstUpload()
        try await Task.sleep(for: .milliseconds(10))

        #expect(uploader.requestedBaseURLs == [firstURL, secondURL])
        #expect(try await outbox.pending(for: deliveryScope).isEmpty)
        #expect(publisher.lastError == nil)
    }

    @Test("A pinned queue records withdrawals while delivery is suspended")
    func suspendedDeliveryRecordsWithdrawal() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let identityID = "thane:ed25519:SHA256:primary"
        let deliveryScope = ObservationDeliveryScope(
            connectionID: "connection-primary",
            identityID: identityID
        )
        let uploader = SequencedObservationUploader()
        let publisher = ObservationPublisher(outbox: outbox, uploader: uploader)

        publisher.configure(
            baseURL: nil,
            token: nil,
            clientID: "",
            deliveryScope: deliveryScope,
            authorizationExpiresAt: nil
        )
        publisher.withdraw(.location)

        try await waitUntil { publisher.pendingCount == 1 }
        let pending = try await outbox.pending(for: deliveryScope)
        #expect(pending.count == 1)
        #expect(pending.first?.kind == .location)
        #expect(pending.first?.status == .withdrawn)
        #expect(uploader.callCount == 0)
    }

    @Test("Expired identity authorization blocks event-driven private observations")
    func expiredAuthorizationBlocksPrivateObservations() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let uploader = SequencedObservationUploader()
        let publisher = ObservationPublisher(
            outbox: ObservationOutbox(fileURL: fixture.fileURL),
            uploader: uploader
        )
        let deliveryScope = ObservationDeliveryScope(
            connectionID: "connection-primary",
            identityID: "thane:ed25519:SHA256:primary"
        )
        let baseURL = try #require(URL(string: "https://thane.example"))

        publisher.configure(
            baseURL: baseURL,
            token: "token",
            clientID: "client-id",
            deliveryScope: deliveryScope,
            authorizationExpiresAt: .distantPast
        )
        publisher.publishLocation(Self.locationSnapshot())
        try await Task.sleep(for: .milliseconds(50))

        #expect(uploader.callCount == 0)
        #expect(publisher.pendingCount == 0)
    }

    @Test("Forgetting drains pending mutations before deleting the queue")
    func forgettingDrainsPendingMutations() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        let identityID = "thane:ed25519:SHA256:primary"
        let deliveryScope = ObservationDeliveryScope(
            connectionID: "connection-primary",
            identityID: identityID
        )
        let publisher = ObservationPublisher(
            outbox: outbox,
            uploader: SequencedObservationUploader()
        )

        publisher.configure(
            baseURL: nil,
            token: nil,
            clientID: "",
            deliveryScope: deliveryScope,
            authorizationExpiresAt: nil
        )
        publisher.withdraw(.location)
        publisher.withdraw(.systemContext)

        try await publisher.discardAllPending()
        try await Task.sleep(for: .milliseconds(10))

        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
        await #expect(throws: ObservationOutboxError.self) {
            _ = try await outbox.pending(for: deliveryScope)
        }
        #expect(publisher.pendingCount == 0)
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for asynchronous publisher state")
    }

    private static func locationSnapshot() -> LocationSnapshot {
        LocationSnapshot(
            capturedAt: "2026-09-01T12:00:00Z",
            locationTimestamp: "2026-09-01T12:00:00Z",
            latitude: 41.88,
            longitude: -87.63,
            altitudeMeters: nil,
            ellipsoidalAltitudeMeters: nil,
            horizontalAccuracyMeters: 5,
            verticalAccuracyMeters: nil,
            speedMetersPerSecond: nil,
            speedAccuracyMetersPerSecond: nil,
            courseDegrees: nil,
            courseAccuracyDegrees: nil,
            floor: nil,
            authorization: "always",
            accuracyAuthorization: "full",
            simulatedBySoftware: false,
            producedByAccessory: false
        )
    }
}

@MainActor
private final class SequencedObservationUploader: ObservationUploading {
    private(set) var callCount = 0
    private(set) var requestedBaseURLs: [URL] = []
    private var firstContinuation: CheckedContinuation<ObservationIngestResult, Error>?

    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult {
        callCount += 1
        requestedBaseURLs.append(baseURL)
        if callCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return ObservationIngestResult(stored: batch.events.count, ignored: 0, receivedAt: Date())
    }

    func failFirstUpload() {
        firstContinuation?.resume(throwing: PublisherTestError.expectedFailure)
        firstContinuation = nil
    }
}

private enum PublisherTestError: Error {
    case expectedFailure
}

private struct PublisherTestPayload: Codable, Sendable {
    let value: Int
}

private final class PublisherFixture: @unchecked Sendable {
    let directoryURL: URL
    let fileURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObservationPublisherTests-\(UUID().uuidString)", isDirectory: true)
        fileURL = directoryURL.appendingPathComponent("outbox.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
