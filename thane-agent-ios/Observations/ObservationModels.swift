import Foundation

nonisolated enum ObservationKind: String, Codable, CaseIterable, Sendable {
    case location = "ios.location"
    case systemContext = "ios.system-context"
}

nonisolated enum ObservationStatus: String, Codable, Sendable {
    case available
    case withdrawn
}

nonisolated struct ObservationEvent: Codable, Sendable, Equatable {
    let eventID: UUID
    let kind: ObservationKind
    let schemaVersion: Int
    let status: ObservationStatus
    let observedAt: Date
    let payload: AnyCodable?

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case kind
        case schemaVersion = "schema_version"
        case status
        case observedAt = "observed_at"
        case payload
    }

    static func available<T: Encodable & Sendable>(
        kind: ObservationKind,
        observedAt: Date,
        payload: T
    ) throws -> ObservationEvent {
        ObservationEvent(
            eventID: UUID(),
            kind: kind,
            schemaVersion: 1,
            status: .available,
            observedAt: observedAt,
            payload: try AnyCodable.fromEncodable(payload)
        )
    }

    static func withdrawn(kind: ObservationKind, observedAt: Date = Date()) -> ObservationEvent {
        ObservationEvent(
            eventID: UUID(),
            kind: kind,
            schemaVersion: 1,
            status: .withdrawn,
            observedAt: observedAt,
            payload: nil
        )
    }

    static func == (lhs: ObservationEvent, rhs: ObservationEvent) -> Bool {
        guard lhs.eventID == rhs.eventID,
              lhs.kind == rhs.kind,
              lhs.schemaVersion == rhs.schemaVersion,
              lhs.status == rhs.status,
              lhs.observedAt == rhs.observedAt else {
            return false
        }
        return encodedPayload(lhs.payload) == encodedPayload(rhs.payload)
    }

    private static func encodedPayload(_ payload: AnyCodable?) -> Data? {
        try? JSONEncoder().encode(payload)
    }
}

nonisolated struct ObservationBatch: Codable, Sendable {
    let clientID: String
    let clientName: String
    let platform: String
    let appVersion: String
    let osVersion: String
    let events: [ObservationEvent]

    enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case clientName = "client_name"
        case platform
        case appVersion = "app_version"
        case osVersion = "os_version"
        case events
    }
}

nonisolated struct ObservationIngestResult: Codable, Sendable {
    let stored: Int
    let ignored: Int
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case stored, ignored
        case receivedAt = "received_at"
    }
}

nonisolated enum ObservationCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(dateString(from: date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = date(from: value) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO 8601 date."
                )
            }
            return date
        }
        return decoder
    }

    static func date(from value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func dateString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
