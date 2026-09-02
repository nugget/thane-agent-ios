import CryptoKit
import Foundation

nonisolated enum InboxStoreError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case identityRequired
    case identityMismatch
    case invalidRecord(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            "Inbox unavailable: \(message)"
        case .identityRequired:
            "Inbox access requires a pinned Thane identity."
        case .identityMismatch:
            "Inbox content belongs to a different connection or Thane identity."
        case .invalidRecord(let message):
            "Inbox item is invalid: \(message)"
        }
    }
}

private nonisolated struct InboxArchive: Codable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let profileID: String
    let counterpartyID: String
    let records: [InboxRecord]

    init(profileID: String, counterpartyID: String, records: [InboxRecord]) {
        schemaVersion = Self.currentSchemaVersion
        self.profileID = profileID
        self.counterpartyID = counterpartyID
        self.records = records
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profileID = "profile_id"
        case counterpartyID = "counterparty_id"
        case records
    }
}

@Observable
@MainActor
final class InboxStore {
    nonisolated static let maximumRecordCount = 500

    private(set) var records: [InboxRecord] = []
    private(set) var boundCounterpartyID: String?
    private(set) var lastError: String?

    private let profileID: String
    private let storageDirectoryURL: URL
    private let initializationError: InboxStoreError?
    private var scopeIsAvailable = false

    init(
        profileID: String,
        storageDirectoryURL: URL? = nil
    ) {
        self.profileID = profileID
        do {
            guard !profileID.isEmpty else {
                throw InboxStoreError.unavailable(
                    "A stable profile ID is required for persisted inbox storage."
                )
            }
            self.storageDirectoryURL = try storageDirectoryURL
                ?? Self.defaultStorageDirectoryURL()
            initializationError = nil
        } catch let error as InboxStoreError {
            self.storageDirectoryURL = FileManager.default.temporaryDirectory
            initializationError = error
            lastError = error.localizedDescription
        } catch {
            self.storageDirectoryURL = FileManager.default.temporaryDirectory
            let storeError = InboxStoreError.unavailable(error.localizedDescription)
            initializationError = storeError
            lastError = storeError.localizedDescription
        }
    }

    var unreadCount: Int {
        records.lazy.filter { !$0.isRead }.count
    }

    func record(id: String) -> InboxRecord? {
        records.first { $0.id == id }
    }

    func scope(to counterpartyID: String?) {
        records = []
        boundCounterpartyID = counterpartyID
        scopeIsAvailable = false
        lastError = initializationError?.localizedDescription

        guard let counterpartyID else { return }

        do {
            try ensureAvailable()
            guard !counterpartyID.isEmpty else {
                throw InboxStoreError.identityRequired
            }
            let fileURL = archiveURL(counterpartyID: counterpartyID)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                let archive = try Self.decoder().decode(InboxArchive.self, from: data)
                guard archive.schemaVersion == InboxArchive.currentSchemaVersion else {
                    throw InboxStoreError.unavailable(
                        "The saved inbox uses an unsupported storage schema."
                    )
                }
                guard archive.profileID == profileID,
                      archive.counterpartyID == counterpartyID else {
                    throw InboxStoreError.identityMismatch
                }
                for record in archive.records {
                    try Self.validate(record, counterpartyID: counterpartyID)
                }
                records = Self.normalized(archive.records)
            }
            scopeIsAvailable = true
        } catch let error as InboxStoreError {
            lastError = error.localizedDescription
        } catch {
            lastError = InboxStoreError.unavailable(error.localizedDescription).localizedDescription
        }
    }

    func upsert(_ record: InboxRecord) throws {
        try ensureBoundAndAvailable()
        guard let counterpartyID = boundCounterpartyID else {
            throw InboxStoreError.identityRequired
        }
        try Self.validate(record, counterpartyID: counterpartyID)

        let previous = records
        records.removeAll { $0.id == record.id }
        records.append(record)
        records = Self.normalized(records)
        do {
            try persist()
            lastError = nil
        } catch {
            records = previous
            lastError = error.localizedDescription
            throw error
        }
    }

    func markRead(id: String) throws {
        try ensureBoundAndAvailable()
        guard let index = records.firstIndex(where: { $0.id == id }),
              !records[index].isRead else {
            return
        }

        let previous = records
        records[index].isRead = true
        do {
            try persist()
            lastError = nil
        } catch {
            records = previous
            lastError = error.localizedDescription
            throw error
        }
    }

    func markAllRead() throws {
        try ensureBoundAndAvailable()
        guard records.contains(where: { !$0.isRead }) else { return }

        let previous = records
        for index in records.indices {
            records[index].isRead = true
        }
        do {
            try persist()
            lastError = nil
        } catch {
            records = previous
            lastError = error.localizedDescription
            throw error
        }
    }

    func discardAllProfileData() throws {
        try ensureAvailable()
        let directoryURL = profileDirectoryURL
        do {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.removeItem(at: directoryURL)
            }
            records = []
            boundCounterpartyID = nil
            scopeIsAvailable = false
            lastError = nil
        } catch {
            lastError = InboxStoreError.unavailable(error.localizedDescription).localizedDescription
            throw error
        }
    }

    private func persist() throws {
        try ensureBoundAndAvailable()
        guard let counterpartyID = boundCounterpartyID else {
            throw InboxStoreError.identityRequired
        }
        let fileURL = archiveURL(counterpartyID: counterpartyID)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let archive = InboxArchive(
            profileID: profileID,
            counterpartyID: counterpartyID,
            records: records
        )
        let data = try Self.encoder().encode(archive)
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

    private func ensureBoundAndAvailable() throws {
        try ensureAvailable()
        guard boundCounterpartyID != nil else {
            throw InboxStoreError.identityRequired
        }
        guard scopeIsAvailable else {
            throw InboxStoreError.unavailable(
                "The selected inbox could not be loaded safely."
            )
        }
    }

    private var profileDirectoryURL: URL {
        Self.profileDirectoryURL(
            profileID: profileID,
            storageDirectoryURL: storageDirectoryURL
        )
    }

    private func archiveURL(counterpartyID: String) -> URL {
        profileDirectoryURL
            .appendingPathComponent("\(Self.digest(counterpartyID)).json", isDirectory: false)
    }

    nonisolated static func profileDirectoryURL(
        profileID: String,
        storageDirectoryURL: URL
    ) -> URL {
        storageDirectoryURL
            .appendingPathComponent("inboxes", isDirectory: true)
            .appendingPathComponent(digest(profileID), isDirectory: true)
    }

    private nonisolated static func validate(
        _ record: InboxRecord,
        counterpartyID: String
    ) throws {
        guard record.counterpartyID == counterpartyID else {
            throw InboxStoreError.identityMismatch
        }
        guard isValidRouteIdentifier(record.id, maximumLength: 128) else {
            throw InboxStoreError.invalidRecord("Its identifier is not a bounded routing identifier.")
        }
        guard !record.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              record.title.utf8.count <= 512 else {
            throw InboxStoreError.invalidRecord("Its title must contain 1 to 512 UTF-8 bytes.")
        }
        guard record.summary.utf8.count <= 4_096 else {
            throw InboxStoreError.invalidRecord("Its summary exceeds 4,096 UTF-8 bytes.")
        }
        if let conversationID = record.relatedConversationID,
           !isValidRouteIdentifier(conversationID, maximumLength: 128) {
            throw InboxStoreError.invalidRecord(
                "Its related conversation identifier is not a bounded routing identifier."
            )
        }
    }

    private nonisolated static func normalized(_ records: [InboxRecord]) -> [InboxRecord] {
        var recordsByID: [String: InboxRecord] = [:]
        for record in records {
            guard let existing = recordsByID[record.id] else {
                recordsByID[record.id] = record
                continue
            }
            if record.createdAt > existing.createdAt
                || (record.createdAt == existing.createdAt && record.isRead && !existing.isRead) {
                recordsByID[record.id] = record
            }
        }
        return recordsByID.values
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt > $1.createdAt
                }
                return $0.id > $1.id
            }
            .prefix(maximumRecordCount)
            .map { $0 }
    }

    private nonisolated static func isValidRouteIdentifier(
        _ value: String,
        maximumLength: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= maximumLength,
              value != ".",
              value != ".." else {
            return false
        }
        return bytes.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "."),
                 UInt8(ascii: "_"), UInt8(ascii: "~"):
                true
            default:
                false
            }
        }
    }

    private nonisolated static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private nonisolated static func defaultStorageDirectoryURL() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("info.nugget.thane-agent-ios", isDirectory: true)
    }

    private nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
