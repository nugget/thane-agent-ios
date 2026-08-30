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
    private var identityID: String?
    private var preparedIdentityID: String?
    private var uploadTask: Task<Void, Never>?
    private var uploadID: UUID?
    private var preparationTask: Task<Void, Never>?
    private var enqueueTasks: [UUID: Task<Void, Never>] = [:]
    private var flushRequestedWhileBusy = false

    init(
        outbox: ObservationOutbox = ObservationOutbox(),
        uploader: any ObservationUploading = URLSessionObservationUploader()
    ) {
        self.outbox = outbox
        self.uploader = uploader
    }

    func configure(
        baseURL: URL?,
        token: String?,
        clientID: String,
        identityID: String?
    ) {
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationChanged = self.baseURL != baseURL
            || self.token != trimmedToken
            || self.clientID != clientID
            || self.identityID != identityID
        if destinationChanged {
            uploadTask?.cancel()
            uploadTask = nil
            uploadID = nil
            preparationTask?.cancel()
            preparedIdentityID = nil
            flushRequestedWhileBusy = false
            isUploading = false
        }
        if self.identityID != identityID {
            for task in enqueueTasks.values {
                task.cancel()
            }
        }
        self.baseURL = baseURL
        self.token = trimmedToken
        self.clientID = clientID
        self.identityID = identityID

        guard destinationChanged else {
            flush()
            return
        }

        guard let identityID else {
            pendingCount = 0
            isUploading = false
            return
        }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discardedCount = try await outbox.bind(to: identityID)
                try Task.checkCancellation()
                guard self.identityID == identityID else { return }
                preparedIdentityID = identityID
                if discardedCount > 0 {
                    logger.notice(
                        "Discarded \(discardedCount, privacy: .public) legacy observations without an identity scope"
                    )
                }
                lastError = nil
                await refreshPendingCount(for: identityID)
                flush()
            } catch is CancellationError {
                return
            } catch {
                guard self.identityID == identityID else { return }
                record(error)
            }
        }
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
              let identityID,
              preparedIdentityID == identityID,
              !token.isEmpty,
              !clientID.isEmpty else {
            return
        }
        guard uploadTask == nil else {
            flushRequestedWhileBusy = true
            return
        }

        isUploading = true
        let clientID = clientID
        let uploadID = UUID()
        self.uploadID = uploadID
        uploadTask = Task { [weak self] in
            guard let self else { return }
            await self.performUpload(
                baseURL: baseURL,
                token: token,
                clientID: clientID,
                identityID: identityID,
                uploadID: uploadID
            )
        }
    }

    func discardAllPending() async throws {
        let activeUpload = uploadTask
        let activePreparation = preparationTask
        let activeEnqueues = Array(enqueueTasks.values)
        activeUpload?.cancel()
        activePreparation?.cancel()
        for task in activeEnqueues {
            task.cancel()
        }

        // Clear the destination before yielding so callbacks cannot create a
        // new scoped write while the existing work is being drained.
        baseURL = nil
        token = nil
        clientID = ""
        identityID = nil
        preparedIdentityID = nil
        uploadTask = nil
        uploadID = nil
        preparationTask = nil
        flushRequestedWhileBusy = false
        isUploading = false

        await activeUpload?.value
        await activePreparation?.value
        for task in activeEnqueues {
            await task.value
        }
        try await outbox.discardAll()
        pendingCount = 0
        lastPublishedAt = nil
        lastError = nil
    }

    private func enqueue(_ makeEvent: @escaping @MainActor () throws -> ObservationEvent) {
        guard let identityID else { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { enqueueTasks[taskID] = nil }
            do {
                try Task.checkCancellation()
                let event = try makeEvent()
                try Task.checkCancellation()
                try await outbox.enqueue(event, for: identityID)
                try Task.checkCancellation()
                guard self.identityID == identityID else { return }
                preparedIdentityID = identityID
                lastError = nil
                await refreshPendingCount(for: identityID)
                flush()
            } catch is CancellationError {
                return
            } catch {
                if self.identityID == identityID {
                    record(error)
                }
            }
        }
        enqueueTasks[taskID] = task
    }

    private func performUpload(
        baseURL: URL,
        token: String,
        clientID: String,
        identityID: String,
        uploadID: UUID
    ) async {
        var completedBatch = false
        let backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Publish companion observations"
        ) { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelUpload(id: uploadID)
            }
        }
        defer {
            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
            }
        }

        do {
            let events = try await outbox.pending(for: identityID)
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
                try await outbox.removeSent(Set(batch.events.map(\.eventID)), for: identityID)
                completedBatch = true
                if self.identityID == identityID {
                    lastPublishedAt = Date()
                    lastError = nil
                }
                logger.info("Published \(batch.events.count, privacy: .public) companion observation kinds")
            }
        } catch is CancellationError {
            logger.notice("Observation upload ended when background time expired")
        } catch {
            if self.uploadID == uploadID,
               self.identityID == identityID {
                record(error)
            }
        }

        guard self.uploadID == uploadID else { return }
        if self.identityID == identityID {
            await refreshPendingCount(for: identityID)
        }
        let shouldFlushAgain = flushRequestedWhileBusy || completedBatch
        flushRequestedWhileBusy = false
        uploadTask = nil
        self.uploadID = nil
        isUploading = false
        if shouldFlushAgain,
           pendingCount > 0,
           self.baseURL != nil,
           self.token?.isEmpty == false,
           self.identityID == identityID {
            // A registration or newer coalesced value requested one more attempt
            // while this batch was in flight. A failure without such a request
            // still stops here rather than creating a retry loop.
            flush()
        }
    }

    private func refreshPendingCount(for identityID: String) async {
        do {
            let count = try await outbox.pending(for: identityID).count
            guard self.identityID == identityID else { return }
            pendingCount = count
        } catch {
            if self.identityID == identityID {
                record(error)
            }
        }
    }

    private func cancelUpload(id: UUID) {
        guard uploadID == id else { return }
        uploadTask?.cancel()
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
