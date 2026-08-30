import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Observation publisher")
@MainActor
struct ObservationPublisherTests {
    @Test("A flush requested during a failed upload runs once afterward")
    func deferredFlushAfterFailure() async throws {
        let fixture = try PublisherFixture()
        defer { fixture.cleanup() }
        let outbox = ObservationOutbox(fileURL: fixture.fileURL)
        try await outbox.enqueue(try ObservationEvent.available(
            kind: .systemContext,
            observedAt: Date(),
            payload: PublisherTestPayload(value: 1)
        ))
        let uploader = SequencedObservationUploader()
        let publisher = ObservationPublisher(outbox: outbox, uploader: uploader)
        let baseURL = try #require(URL(string: "https://thane.example"))

        publisher.configure(baseURL: baseURL, token: "token", clientID: "client-id")
        try await waitUntil { uploader.callCount == 1 }

        publisher.flush()
        uploader.failFirstUpload()

        try await waitUntil { uploader.callCount == 2 }
        try await waitUntil { publisher.pendingCount == 0 && !publisher.isUploading }
        #expect(try await outbox.pending().isEmpty)
        #expect(uploader.callCount == 2)
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
}

@MainActor
private final class SequencedObservationUploader: ObservationUploading {
    private(set) var callCount = 0
    private var firstContinuation: CheckedContinuation<ObservationIngestResult, Error>?

    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult {
        callCount += 1
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
