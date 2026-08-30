import Foundation

nonisolated enum ObservationOutboxError: LocalizedError, Sendable {
    case unavailable(String)
    case identityRequired
    case identityMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "Observation queue unavailable: \(message)"
        case .identityRequired:
            "Observation queue requires a pinned Thane identity."
        case .identityMismatch:
            "Observation queue belongs to a different Thane identity."
        }
    }
}

private nonisolated struct ObservationOutboxEnvelope: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let identityID: String
    let events: [ObservationEvent]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case identityID = "identity_id"
        case events
    }
}

actor ObservationOutbox {
    private let fileURL: URL
    private let storageURLResolved: Bool
    private var identityID: String?
    private var eventsByKind: [ObservationKind: ObservationEvent] = [:]
    private var initializationError: ObservationOutboxError?
    private var legacyEventCount = 0

    init(fileURL: URL? = nil) {
        var resolvedURL = fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thane-observations-unavailable.json")
        var loadedIdentityID: String?
        var loadedEvents: [ObservationKind: ObservationEvent] = [:]
        var loadError: ObservationOutboxError?
        var loadedLegacyEventCount = 0
        var didResolveStorageURL = false
        do {
            resolvedURL = try fileURL ?? Self.defaultFileURL()
            didResolveStorageURL = true
            if FileManager.default.fileExists(atPath: resolvedURL.path) {
                let data = try Data(contentsOf: resolvedURL)
                let events: [ObservationEvent]
                do {
                    let envelope = try ObservationCoding.decoder().decode(
                        ObservationOutboxEnvelope.self,
                        from: data
                    )
                    guard envelope.schemaVersion == ObservationOutboxEnvelope.currentSchemaVersion,
                          !envelope.identityID.isEmpty else {
                        throw ObservationOutboxError.unavailable(
                            "The saved queue uses an unsupported storage schema."
                        )
                    }
                    loadedIdentityID = envelope.identityID
                    events = envelope.events
                } catch let error as ObservationOutboxError {
                    throw error
                } catch {
                    // Version 1 of the app stored a bare event array without a
                    // recipient. Those events cannot safely be assigned to a
                    // newly pinned identity, so remember only the discard count.
                    let legacyEvents = try ObservationCoding.decoder().decode(
                        [ObservationEvent].self,
                        from: data
                    )
                    loadedLegacyEventCount = legacyEvents.count
                    events = []
                }
                for event in events {
                    guard let existing = loadedEvents[event.kind] else {
                        loadedEvents[event.kind] = event
                        continue
                    }
                    if Self.shouldReplace(existing, with: event) {
                        loadedEvents[event.kind] = event
                    }
                }
            }
        } catch let error as ObservationOutboxError {
            loadError = error
        } catch {
            loadError = .unavailable(error.localizedDescription)
        }
        self.fileURL = resolvedURL
        storageURLResolved = didResolveStorageURL
        identityID = loadedIdentityID
        eventsByKind = loadedEvents
        initializationError = loadError
        legacyEventCount = loadedLegacyEventCount
    }

    @discardableResult
    func bind(to identityID: String) throws -> Int {
        try Task.checkCancellation()
        try ensureAvailable()
        guard !identityID.isEmpty else { throw ObservationOutboxError.identityRequired }
        if let existingIdentityID = self.identityID {
            guard existingIdentityID == identityID else {
                throw ObservationOutboxError.identityMismatch
            }
            return 0
        }

        let discardedCount = legacyEventCount
        let previousIdentityID = self.identityID
        self.identityID = identityID
        legacyEventCount = 0
        do {
            try persist()
        } catch {
            self.identityID = previousIdentityID
            legacyEventCount = discardedCount
            throw error
        }
        return discardedCount
    }

    func enqueue(_ event: ObservationEvent, for identityID: String) throws {
        try Task.checkCancellation()
        try bind(to: identityID)
        try Task.checkCancellation()
        let previous = eventsByKind[event.kind]
        if let previous, !Self.shouldReplace(previous, with: event) {
            return
        }
        eventsByKind[event.kind] = event
        do {
            try persist()
        } catch {
            eventsByKind[event.kind] = previous
            throw error
        }
    }

    func pending(for identityID: String) throws -> [ObservationEvent] {
        try ensureAvailable()
        try requireIdentity(identityID)
        return eventsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    func removeSent(_ eventIDs: Set<UUID>, for identityID: String) throws {
        try Task.checkCancellation()
        try ensureAvailable()
        try requireIdentity(identityID)
        let previous = eventsByKind
        eventsByKind = eventsByKind.filter { !eventIDs.contains($0.value.eventID) }
        do {
            try persist()
        } catch {
            eventsByKind = previous
            throw error
        }
    }

    func discardAll(for identityID: String) throws {
        try ensureAvailable()
        if let existingIdentityID = self.identityID,
           existingIdentityID != identityID {
            throw ObservationOutboxError.identityMismatch
        }

        try discardAll()
    }

    func discardAll() throws {
        let previousIdentityID = self.identityID
        let previousEvents = eventsByKind
        let previousLegacyEventCount = legacyEventCount
        self.identityID = nil
        eventsByKind = [:]
        legacyEventCount = 0
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            if storageURLResolved {
                initializationError = nil
            }
        } catch {
            self.identityID = previousIdentityID
            eventsByKind = previousEvents
            legacyEventCount = previousLegacyEventCount
            throw error
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        guard let identityID else { throw ObservationOutboxError.identityRequired }
        let envelope = ObservationOutboxEnvelope(
            schemaVersion: ObservationOutboxEnvelope.currentSchemaVersion,
            identityID: identityID,
            events: eventsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
        let data = try ObservationCoding.encoder().encode(envelope)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func ensureAvailable() throws {
        if let initializationError {
            throw initializationError
        }
    }

    private func requireIdentity(_ identityID: String) throws {
        guard let existingIdentityID = self.identityID else {
            throw ObservationOutboxError.identityRequired
        }
        guard existingIdentityID == identityID else {
            throw ObservationOutboxError.identityMismatch
        }
    }

    private nonisolated static func shouldReplace(
        _ existing: ObservationEvent,
        with candidate: ObservationEvent
    ) -> Bool {
        guard candidate.eventID != existing.eventID else { return false }
        if candidate.observedAt != existing.observedAt {
            return candidate.observedAt > existing.observedAt
        }
        if candidate.status != existing.status {
            return candidate.status == .withdrawn
        }
        return candidate.eventID.uuidString > existing.eventID.uuidString
    }

    private nonisolated static func defaultFileURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("info.nugget.thane-agent-ios", isDirectory: true)
        .appendingPathComponent("observation-outbox.json", isDirectory: false)
    }
}
