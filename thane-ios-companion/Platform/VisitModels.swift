import CoreLocation
import Foundation

/// Whether an arrival time is real or was never observed.
///
/// CoreLocation signals a missed arrival with `Date.distantPast`, which is a
/// sentinel rather than a time. Passing it through would be a lie the reader
/// cannot detect, and — because it predates the server's 2000-01-01 floor —
/// using it as an event timestamp rejects the whole upload batch, taking
/// unrelated location and system-context events down with it.
nonisolated enum VisitBoundary: String, Codable, Sendable {
    case precise
    case unknown
}

/// Whether the operator has left this place yet.
nonisolated enum VisitState: String, Codable, Sendable {
    case settled
    case ongoing
}

/// One visit: somewhere the operator lingered, and for how long.
nonisolated struct VisitSnapshot: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let horizontalAccuracyMeters: Double
    let arrival: VisitBoundary
    let arrivedAt: String?
    let departedAt: String?
    let state: VisitState
    let dwellSeconds: Double?
    let dwellIsPartial: Bool

    enum CodingKeys: String, CodingKey {
        case latitude, longitude, arrival, state
        case horizontalAccuracyMeters = "horizontal_accuracy_meters"
        case arrivedAt = "arrived_at"
        case departedAt = "departed_at"
        case dwellSeconds = "dwell_seconds"
        case dwellIsPartial = "dwell_is_partial"
    }

    /// The instant this visit is anchored to for ordering and freshness: the
    /// departure when settled, the capture time while ongoing. Never the
    /// arrival, which may be a sentinel.
    var anchorDate: Date {
        if let departedAt, let parsed = ObservationCoding.date(from: departedAt) {
            return parsed
        }
        if let arrivedAt, let parsed = ObservationCoding.date(from: arrivedAt) {
            return parsed
        }
        return .distantPast
    }

    /// Built from CoreLocation's scalars rather than from `CLVisit` itself.
    ///
    /// `CLVisit` has no public initialiser, so a builder taking one cannot be
    /// exercised in a test. Taking the four values it carries keeps every
    /// sentinel and boundary decision testable, and leaves the delegate a
    /// two-line adapter.
    static func make(
        coordinate: CLLocationCoordinate2D,
        horizontalAccuracy: CLLocationAccuracy,
        arrivalDate: Date,
        departureDate: Date,
        capturedAt: Date
    ) -> VisitSnapshot? {
        guard CLLocationCoordinate2DIsValid(coordinate), horizontalAccuracy >= 0 else {
            return nil
        }
        let arrivalKnown = arrivalDate != .distantPast
        let departed = departureDate != .distantFuture
        let departureInstant = departed ? departureDate : capturedAt

        var dwell: Double?
        if arrivalKnown {
            dwell = max(0, departureInstant.timeIntervalSince(arrivalDate))
        }

        return VisitSnapshot(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            horizontalAccuracyMeters: horizontalAccuracy,
            arrival: arrivalKnown ? .precise : .unknown,
            arrivedAt: arrivalKnown ? ObservationCoding.dateString(from: arrivalDate) : nil,
            departedAt: departed ? ObservationCoding.dateString(from: departureDate) : nil,
            state: departed ? .settled : .ongoing,
            dwellSeconds: dwell,
            dwellIsPartial: !departed
        )
    }
}

/// A bounded window of recent visits, republished whole on every change.
///
/// It has to be a list rather than one visit per event: the outbox keeps a
/// single event per kind (`eventsByKind`), so two visits settling between
/// flushes would silently discard the first. Re-sending the window makes the
/// latest row self-superseding and lossless within its bounds.
nonisolated struct VisitWindowSnapshot: Codable, Equatable, Sendable {
    static let maxEntries = 16
    static let windowHours = 48.0

    let capturedAt: String
    let windowHours: Double
    let maxEntries: Int
    let returnedCount: Int
    let truncated: Bool
    let visits: [VisitSnapshot]

    enum CodingKeys: String, CodingKey {
        case visits, truncated
        case capturedAt = "captured_at"
        case windowHours = "window_hours"
        case maxEntries = "max_entries"
        case returnedCount = "returned_count"
    }
}
