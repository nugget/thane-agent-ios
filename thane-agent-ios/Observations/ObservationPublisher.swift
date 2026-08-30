import Foundation
import os
import UIKit

@Observable
@MainActor
final class ObservationPublisher {
    private(set) var pendingCount = 0
    private(set) var lastPublishedAt: Date?
    private(set) var lastError: String?
    private(set) var isUploading = false

    private let logger = Logger(
        subsystem: "info.nugget.thane-agent-ios",
        category: "observations"
    )
    private let outbox: ObservationOutbox
    private let uploader: any ObservationUploading
    private var baseURL: URL?
    private var token: String?
    private var clientID = ""
    private var uploadTask: Task<Void, Never>?
    private var flushRequestedWhileBusy = false

    init(
        outbox: ObservationOutbox = ObservationOutbox(),
        uploader: any ObservationUploading = URLSessionObservationUploader()
    ) {
        self.outbox = outbox
        self.uploader = uploader
        Task { [weak self] in
            await self?.refreshPendingCount()
        }
    }

    func configure(baseURL: URL?, token: String?, clientID: String) {
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL == nil || trimmedToken?.isEmpty != false {
            uploadTask?.cancel()
        }
        self.baseURL = baseURL
        self.token = trimmedToken
        self.clientID = clientID
        flush()
    }

    func publishLocation(_ snapshot: LocationSnapshot) {
        guard let observedAt = ObservationCoding.date(from: snapshot.locationTimestamp) else {
            lastError = "A Core Location timestamp could not be encoded."
            return
        }
        enqueue {
            try ObservationEvent.available(
                kind: .location,
                observedAt: observedAt,
                payload: snapshot
            )
        }
    }

    func publishSystemContext(_ snapshot: SystemContextSnapshot) {
        guard let observedAt = ObservationCoding.date(from: snapshot.capturedAt) else {
            lastError = "A system-context timestamp could not be encoded."
            return
        }
        enqueue {
            try ObservationEvent.available(
                kind: .systemContext,
                observedAt: observedAt,
                payload: snapshot
            )
        }
    }

    func withdraw(_ kind: ObservationKind) {
        enqueue { ObservationEvent.withdrawn(kind: kind) }
    }

    func flush() {
        guard let baseURL,
              let token,
              !token.isEmpty,
              !clientID.isEmpty else {
            return
        }
        guard uploadTask == nil else {
            flushRequestedWhileBusy = true
            return
        }

        isUploading = true
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.performUpload(baseURL: baseURL, token: token)
        }
    }

    private func enqueue(_ makeEvent: @escaping @MainActor () throws -> ObservationEvent) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await outbox.enqueue(makeEvent())
                lastError = nil
                await refreshPendingCount()
                flush()
            } catch {
                record(error)
            }
        }
    }

    private func performUpload(baseURL: URL, token: String) async {
        var completedBatch = false
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Publish companion observations"
        ) { [weak self] in
            self?.uploadTask?.cancel()
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        do {
            let events = try await outbox.pending()
            if !events.isEmpty {
                let batch = ObservationBatch(
                    clientID: clientID,
                    clientName: "Thane for iOS",
                    platform: "ios",
                    appVersion: Self.appVersion,
                    osVersion: UIDevice.current.systemVersion,
                    events: Array(events.prefix(16))
                )
                _ = try await uploader.upload(batch, to: baseURL, token: token)
                try Task.checkCancellation()
                try await outbox.removeSent(Set(batch.events.map(\.eventID)))
                completedBatch = true
                lastPublishedAt = Date()
                lastError = nil
                logger.info("Published \(batch.events.count, privacy: .public) companion observation kinds")
            }
        } catch is CancellationError {
            logger.notice("Observation upload ended when background time expired")
        } catch {
            record(error)
        }

        await refreshPendingCount()
        let shouldFlushAgain = flushRequestedWhileBusy || completedBatch
        flushRequestedWhileBusy = false
        uploadTask = nil
        isUploading = false
        if shouldFlushAgain,
           pendingCount > 0,
           self.baseURL != nil,
           self.token?.isEmpty == false {
            // A registration or newer coalesced value requested one more attempt
            // while this batch was in flight. A failure without such a request
            // still stops here rather than creating a retry loop.
            flush()
        }
    }

    private func refreshPendingCount() async {
        do {
            pendingCount = try await outbox.pending().count
        } catch {
            record(error)
        }
    }

    private func record(_ error: Error) {
        lastError = error.localizedDescription
        logger.error("Observation publication failed: \(error.localizedDescription, privacy: .public)")
    }

    private nonisolated static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): build
        case (nil, nil): "unknown"
        }
    }
}
