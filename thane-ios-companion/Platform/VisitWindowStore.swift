import CryptoKit
import Foundation

/// Holds the recent-visit window on disk so it survives the relaunches this
/// feature depends on.
///
/// It has to persist. Core Location relaunches the app to deliver a visit, and
/// the outbox keeps exactly one event per kind — so an in-memory window would
/// reset on every launch and each publish would replace the server's row with a
/// single entry, destroying the history it is supposed to carry.
///
/// Scoped by profile and file-protected the way the outbox is: two agents must
/// not share a window, and a window must be readable during the after-first-
/// unlock period a background wake actually runs in.
@MainActor
final class VisitWindowStore {
    private let fileURL: URL
    private var visits: [VisitSnapshot] = []

    init(profileID: String, storageDirectoryURL: URL? = nil) {
        let directory = (try? storageDirectoryURL ?? Self.defaultStorageDirectoryURL())
            ?? FileManager.default.temporaryDirectory
        fileURL = Self.profileFileURL(profileID: profileID, storageDirectoryURL: directory)
        visits = (try? load()) ?? []
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        visits = (try? load()) ?? []
    }

    /// Records a visit and returns the window to publish.
    ///
    /// Visits are keyed by their arrival so the settled callback replaces the
    /// ongoing one for the same stay rather than appearing twice — Core
    /// Location delivers both.
    @discardableResult
    func record(_ visit: VisitSnapshot, now: Date = Date()) -> VisitWindowSnapshot {
        visits.removeAll { $0.arrivedAt == visit.arrivedAt && $0.latitude == visit.latitude }
        visits.append(visit)
        prune(now: now)
        try? persist()
        return window(now: now)
    }

    func window(now: Date = Date()) -> VisitWindowSnapshot {
        let ordered = visits.sorted { $0.anchorDate > $1.anchorDate }
        let kept = Array(ordered.prefix(VisitWindowSnapshot.maxEntries))
        return VisitWindowSnapshot(
            capturedAt: ObservationCoding.dateString(from: now),
            windowHours: VisitWindowSnapshot.windowHours,
            maxEntries: VisitWindowSnapshot.maxEntries,
            returnedCount: kept.count,
            truncated: ordered.count > kept.count,
            visits: kept
        )
    }

    var isEmpty: Bool { visits.isEmpty }

    /// Erases the window. Called wherever the operator withdraws visits, so
    /// turning the category off leaves nothing on the device to republish.
    func discardAll() {
        visits = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-VisitWindowSnapshot.windowHours * 3600)
        visits.removeAll { $0.anchorDate < cutoff }
        if visits.count > VisitWindowSnapshot.maxEntries {
            visits = Array(
                visits.sorted { $0.anchorDate > $1.anchorDate }
                    .prefix(VisitWindowSnapshot.maxEntries)
            )
        }
    }

    private func load() throws -> [VisitSnapshot] {
        let data = try Data(contentsOf: fileURL)
        return try ObservationCoding.decoder().decode([VisitSnapshot].self, from: data)
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try ObservationCoding.encoder().encode(visits)
        try data.write(
            to: fileURL,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    nonisolated static func profileFileURL(
        profileID: String,
        storageDirectoryURL: URL
    ) -> URL {
        let digest = SHA256.hash(data: Data(profileID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return storageDirectoryURL
            .appendingPathComponent("visit-windows", isDirectory: true)
            .appendingPathComponent("\(digest).json", isDirectory: false)
    }

    private nonisolated static func defaultStorageDirectoryURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("info.nugget.thane-ios-companion", isDirectory: true)
    }
}

/// The agent-facing read of the recent-visit window.
///
/// Answers from the on-device window rather than from Core Location: visits
/// arrive on the system's schedule, so there is nothing to "request" the way a
/// location fix can be requested. This reports what has already been observed.
@MainActor
struct VisitsPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["get_recent_visits"]
    let toolDefinitions = [
        PlatformToolDefinition.make(
            name: "ios_recent_visits",
            description: "Recent places the operator lingered, with arrival and departure times, from the active iOS companion. Covers at most the last 48 hours and 16 visits. Works only after the operator enables Visit History in the app and grants iOS Always location permission. A visit still in progress has no departure time and a partial dwell. An arrival the system did not observe is reported as unknown rather than guessed.",
            method: "get_recent_visits",
            tags: ["ios", "location", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {}
            }
            """
        ),
    ]

    private let store: VisitWindowStore
    private let preferences: SharingPreferences

    init(store: VisitWindowStore, preferences: SharingPreferences) {
        self.store = store
        self.preferences = preferences
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard method == "get_recent_visits" else {
            throw VisitsHandlerError.unsupportedMethod(method)
        }
        // Re-checked at answer time, not assumed from whatever armed
        // monitoring: the operator may have revoked since.
        guard preferences.locationEnabled, preferences.visitsEnabled else {
            throw VisitsHandlerError.sharingDisabled
        }
        return try AnyCodable.fromEncodable(store.window())
    }
}

nonisolated enum VisitsHandlerError: PlatformServiceError {
    case sharingDisabled
    case unsupportedMethod(String)

    var code: String {
        switch self {
        case .sharingDisabled: "visit_sharing_disabled"
        case .unsupportedMethod: "unknown_method"
        }
    }

    var errorDescription: String? {
        switch self {
        case .sharingDisabled:
            "Visit History is turned off for this agent in the iOS companion."
        case .unsupportedMethod(let method):
            "The visits capability does not support \(method)."
        }
    }
}
