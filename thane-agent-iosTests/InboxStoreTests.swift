import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Identity-bound inbox storage")
@MainActor
struct InboxStoreTests {
    @Test("Records persist for the same profile and counterparty")
    func recordsPersist() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let expected = fixture.record(id: "item-1")

        let store = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try store.upsert(expected)

        let reloaded = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")

        #expect(reloaded.records == [expected])
        #expect(reloaded.unreadCount == 1)
        #expect(reloaded.lastError == nil)
    }

    @Test("One profile keeps counterparties in separate archives")
    func counterpartyIsolation() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let first = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try first.upsert(fixture.record(id: "shared", counterpartyID: "thane:one"))

        first.scope(to: "thane:two")
        #expect(first.records.isEmpty)
        try first.upsert(fixture.record(id: "shared", counterpartyID: "thane:two"))

        first.scope(to: "thane:one")
        #expect(first.records.map(\.counterpartyID) == ["thane:one"])
        first.scope(to: "thane:two")
        #expect(first.records.map(\.counterpartyID) == ["thane:two"])
    }

    @Test("Separate profiles cannot read one another's inbox")
    func profileIsolation() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let first = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try first.upsert(fixture.record(id: "item-1"))

        let second = fixture.store(profileID: "profile-two", counterpartyID: "thane:one")

        #expect(second.records.isEmpty)
        #expect(second.lastError == nil)
        #expect(
            InboxStore.profileDirectoryURL(
                profileID: "profile-one",
                storageDirectoryURL: fixture.directoryURL
            ) != InboxStore.profileDirectoryURL(
                profileID: "profile-two",
                storageDirectoryURL: fixture.directoryURL
            )
        )
    }

    @Test("Suspending a scope hides records and rebinding restores them")
    func scopeSuspensionPreservesRecords() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try store.upsert(fixture.record(id: "item-1"))

        store.scope(to: nil)
        #expect(store.boundCounterpartyID == nil)
        #expect(store.records.isEmpty)
        #expect(throws: InboxStoreError.identityRequired) {
            try store.upsert(fixture.record(id: "blocked"))
        }

        store.scope(to: "thane:one")
        #expect(store.records.map(\.id) == ["item-1"])
    }

    @Test("Read state is durable and updates unread count")
    func readStatePersists() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try store.upsert(fixture.record(id: "item-1"))
        try store.upsert(fixture.record(id: "item-2"))

        try store.markRead(id: "item-1")

        #expect(store.unreadCount == 1)
        let reloaded = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        #expect(reloaded.record(id: "item-1")?.isRead == true)
        #expect(reloaded.record(id: "item-2")?.isRead == false)

        try reloaded.markAllRead()
        #expect(reloaded.unreadCount == 0)
    }

    @Test("Writes reject records belonging to another identity")
    func mismatchedRecordFailsClosed() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")

        #expect(throws: InboxStoreError.identityMismatch) {
            try store.upsert(
                fixture.record(id: "item-1", counterpartyID: "thane:two")
            )
        }
        #expect(store.records.isEmpty)
    }

    @Test("Invalid routing identifiers are rejected before persistence")
    func invalidIdentifiersAreRejected() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")

        #expect(throws: InboxStoreError.self) {
            try store.upsert(fixture.record(id: "private/item"))
        }
        #expect(store.records.isEmpty)
    }

    @Test("A corrupted archive stays unreadable and cannot be overwritten")
    func corruptArchiveFailsClosed() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let original = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try original.upsert(fixture.record(id: "item-1"))
        let archiveURL = try fixture.onlyArchiveURL(profileID: "profile-one")
        try Data("not-json".utf8).write(to: archiveURL, options: .atomic)

        let reloaded = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")

        #expect(reloaded.records.isEmpty)
        #expect(reloaded.lastError != nil)
        #expect(throws: InboxStoreError.self) {
            try reloaded.upsert(fixture.record(id: "replacement"))
        }
        #expect(try Data(contentsOf: archiveURL) == Data("not-json".utf8))
    }

    @Test("Archive identity metadata is checked after hashed path lookup")
    func archiveMetadataMismatchFailsClosed() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let original = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try original.upsert(fixture.record(id: "item-1"))
        let archiveURL = try fixture.onlyArchiveURL(profileID: "profile-one")
        let data = try Data(contentsOf: archiveURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["counterparty_id"] = "thane:two"
        try JSONSerialization.data(withJSONObject: object).write(
            to: archiveURL,
            options: .atomic
        )

        let reloaded = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")

        #expect(reloaded.records.isEmpty)
        #expect(
            reloaded.lastError
                == InboxStoreError.identityMismatch.localizedDescription
        )
    }

    @Test("Reloading bounds retained history to the newest 500 records")
    func historyIsBounded() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let original = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try original.upsert(fixture.record(id: "initial"))
        let archiveURL = try fixture.onlyArchiveURL(profileID: "profile-one")
        let records = (0...InboxStore.maximumRecordCount).map { index in
            InboxRecord(
                id: "item-\(index)",
                counterpartyID: "thane:one",
                kind: .information,
                title: "Update \(index)",
                summary: "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let archive = TestInboxArchive(
            schemaVersion: 1,
            profileID: "profile-one",
            counterpartyID: "thane:one",
            records: records
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(archive).write(to: archiveURL, options: .atomic)

        let reloaded = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")

        #expect(reloaded.records.count == InboxStore.maximumRecordCount)
        #expect(reloaded.records.first?.id == "item-500")
        #expect(reloaded.records.last?.id == "item-1")
    }

    @Test("Removing a profile deletes every counterparty archive")
    func profileRemovalDeletesAllArchives() throws {
        let fixture = try InboxStoreFixture()
        defer { fixture.cleanup() }
        let store = fixture.store(profileID: "profile-one", counterpartyID: "thane:one")
        try store.upsert(fixture.record(id: "first", counterpartyID: "thane:one"))
        store.scope(to: "thane:two")
        try store.upsert(fixture.record(id: "second", counterpartyID: "thane:two"))
        let profileDirectoryURL = InboxStore.profileDirectoryURL(
            profileID: "profile-one",
            storageDirectoryURL: fixture.directoryURL
        )
        #expect(FileManager.default.fileExists(atPath: profileDirectoryURL.path))

        try store.discardAllProfileData()

        #expect(!FileManager.default.fileExists(atPath: profileDirectoryURL.path))
        #expect(store.boundCounterpartyID == nil)
        #expect(store.records.isEmpty)
    }
}

@MainActor
private final class InboxStoreFixture {
    let directoryURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "InboxStoreTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func store(profileID: String, counterpartyID: String) -> InboxStore {
        let store = InboxStore(
            profileID: profileID,
            storageDirectoryURL: directoryURL
        )
        store.scope(to: counterpartyID)
        return store
    }

    func record(
        id: String,
        counterpartyID: String = "thane:one"
    ) -> InboxRecord {
        InboxRecord(
            id: id,
            counterpartyID: counterpartyID,
            kind: .suggestion,
            title: "A useful suggestion",
            summary: "There is a quiet opening in the afternoon.",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            relatedConversationID: "planning"
        )
    }

    func onlyArchiveURL(profileID: String) throws -> URL {
        let directoryURL = InboxStore.profileDirectoryURL(
            profileID: profileID,
            storageDirectoryURL: directoryURL
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        return try #require(files.only)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

private struct TestInboxArchive: Codable {
    let schemaVersion: Int
    let profileID: String
    let counterpartyID: String
    let records: [InboxRecord]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case profileID = "profile_id"
        case counterpartyID = "counterparty_id"
        case records
    }
}
