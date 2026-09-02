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
    private var deliveryScope: ObservationDeliveryScope?
    private var authorizationExpiresAt: Date?
    private var preparedScope: ObservationDeliveryScope?
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
        deliveryScope: ObservationDeliveryScope?,
        authorizationExpiresAt: Date?
    ) {
        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let destinationChanged = self.baseURL != baseURL
            || self.token != trimmedToken
            || self.clientID != clientID
            || self.deliveryScope != deliveryScope
            || self.authorizationExpiresAt != authorizationExpiresAt
        if destinationChanged {
            uploadTask?.cancel()
            uploadTask = nil
            uploadID = nil
            preparationTask?.cancel()
            preparedScope = nil
            flushRequestedWhileBusy = false
            isUploading = false
        }
        if self.deliveryScope != deliveryScope {
            for task in enqueueTasks.values {
                task.cancel()
            }
        }
        self.baseURL = baseURL
        self.token = trimmedToken
        self.clientID = clientID
        self.deliveryScope = deliveryScope
        self.authorizationExpiresAt = authorizationExpiresAt

        guard destinationChanged else {
            flush()
            return
        }

        guard let deliveryScope else {
            pendingCount = 0
            isUploading = false
            return
        }
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discardedCount = try await outbox.bind(to: deliveryScope)
                try Task.checkCancellation()
                guard self.deliveryScope == deliveryScope else { return }
                preparedScope = deliveryScope
                if discardedCount > 0 {
                    logger.notice(
                        "Discarded \(discardedCount, privacy: .public) legacy observations without a recipient scope"
                    )
                }
                lastError = nil
                await refreshPendingCount(for: deliveryScope)
                flush()
            } catch is CancellationError {
                return
            } catch {
                guard self.deliveryScope == deliveryScope else { return }
                record(error)
            }
        }
    }

    func publishLocation(_ snapshot: LocationSnapshot) {
        guard authorizePrivatePublish() else { return }
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
        guard authorizePrivatePublish() else { return }
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
        guard authorizePrivatePublish() else { return }
        guard let baseURL,
              let token,
              let deliveryScope,
              let authorizationExpiresAt,
              preparedScope == deliveryScope,
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
                deliveryScope: deliveryScope,
                authorizationExpiresAt: authorizationExpiresAt,
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
        deliveryScope = nil
        authorizationExpiresAt = nil
        preparedScope = nil
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
        guard let deliveryScope else { return }
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { enqueueTasks[taskID] = nil }
            do {
                try Task.checkCancellation()
                let event = try makeEvent()
                try Task.checkCancellation()
                try await outbox.enqueue(event, for: deliveryScope)
                try Task.checkCancellation()
                guard self.deliveryScope == deliveryScope else { return }
                preparedScope = deliveryScope
                lastError = nil
                await refreshPendingCount(for: deliveryScope)
                flush()
            } catch is CancellationError {
                return
            } catch {
                if self.deliveryScope == deliveryScope {
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
        deliveryScope: ObservationDeliveryScope,
        authorizationExpiresAt: Date,
        uploadID: UUID
    ) async {
        guard authorizationExpiresAt > Date(),
              self.authorizationExpiresAt == authorizationExpiresAt else {
            if self.authorizationExpiresAt == authorizationExpiresAt {
                suspendExpiredPrivateDelivery()
            }
            return
        }
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
            let events = try await outbox.pending(for: deliveryScope)
            if !events.isEmpty {
                guard authorizationExpiresAt > Date(),
                      self.authorizationExpiresAt == authorizationExpiresAt else {
                    if self.authorizationExpiresAt == authorizationExpiresAt {
                        suspendExpiredPrivateDelivery()
                    }
                    return
                }
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
                try await outbox.removeSent(Set(batch.events.map(\.eventID)), for: deliveryScope)
                completedBatch = true
                if self.deliveryScope == deliveryScope {
                    lastPublishedAt = Date()
                    lastError = nil
                }
                logger.info("Published \(batch.events.count, privacy: .public) companion observation kinds")
            }
        } catch is CancellationError {
            logger.notice("Observation upload ended when background time expired")
        } catch {
            if self.uploadID == uploadID,
               self.deliveryScope == deliveryScope {
                record(error)
            }
        }

        guard self.uploadID == uploadID else { return }
        if self.deliveryScope == deliveryScope {
            await refreshPendingCount(for: deliveryScope)
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
           self.deliveryScope == deliveryScope {
            // A registration or newer coalesced value requested one more attempt
            // while this batch was in flight. A failure without such a request
            // still stops here rather than creating a retry loop.
            flush()
        }
    }

    private func refreshPendingCount(for deliveryScope: ObservationDeliveryScope) async {
        do {
            let count = try await outbox.pending(for: deliveryScope).count
            guard self.deliveryScope == deliveryScope else { return }
            pendingCount = count
        } catch {
            if self.deliveryScope == deliveryScope {
                record(error)
            }
        }
    }

    private func cancelUpload(id: UUID) {
        guard uploadID == id else { return }
        uploadTask?.cancel()
    }

    private func authorizePrivatePublish() -> Bool {
        guard let authorizationExpiresAt else { return false }
        guard authorizationExpiresAt > Date() else {
            suspendExpiredPrivateDelivery()
            return false
        }
        return baseURL != nil
            && token?.isEmpty == false
            && !clientID.isEmpty
            && deliveryScope != nil
    }

    private func suspendExpiredPrivateDelivery() {
        logger.notice("Suspended observation delivery because identity evidence expired")
        uploadTask?.cancel()
        uploadTask = nil
        uploadID = nil
        flushRequestedWhileBusy = false
        isUploading = false
        baseURL = nil
        token = nil
        clientID = ""
        authorizationExpiresAt = nil
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
