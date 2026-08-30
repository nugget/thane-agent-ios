import Foundation

nonisolated enum ObservationOutboxError: LocalizedError, Sendable {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "Observation queue unavailable: \(message)"
        }
    }
}

actor ObservationOutbox {
    private let fileURL: URL
    private var eventsByKind: [ObservationKind: ObservationEvent] = [:]
    private var initializationError: ObservationOutboxError?

    init(fileURL: URL? = nil) {
        var resolvedURL = fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("thane-observations-unavailable.json")
        var loadedEvents: [ObservationKind: ObservationEvent] = [:]
        var loadError: ObservationOutboxError?
        do {
            resolvedURL = try fileURL ?? Self.defaultFileURL()
            if FileManager.default.fileExists(atPath: resolvedURL.path) {
                let data = try Data(contentsOf: resolvedURL)
                let events = try ObservationCoding.decoder().decode([ObservationEvent].self, from: data)
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
        } catch {
            loadError = .unavailable(error.localizedDescription)
        }
        self.fileURL = resolvedURL
        eventsByKind = loadedEvents
        initializationError = loadError
    }

    func enqueue(_ event: ObservationEvent) throws {
        try ensureAvailable()
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

    func pending() throws -> [ObservationEvent] {
        try ensureAvailable()
        return eventsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    func removeSent(_ eventIDs: Set<UUID>) throws {
        try ensureAvailable()
        let previous = eventsByKind
        eventsByKind = eventsByKind.filter { !eventIDs.contains($0.value.eventID) }
        do {
            try persist()
        } catch {
            eventsByKind = previous
            throw error
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try ObservationCoding.encoder().encode(
            eventsByKind.values.sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
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
