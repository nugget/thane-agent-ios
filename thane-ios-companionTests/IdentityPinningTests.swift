import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Identity pinning")
@MainActor
struct IdentityPinningTests {
    private let connectionID = "connection-one"
    private let endpoint = URL(string: "https://thane.example")!

    @Test("A pin persists the exact stable identity material")
    func persistenceAndMatching() throws {
        let evidence = try IdentityTestFixture.evidence()
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        let pinnedAt = Date(timeIntervalSince1970: 1_777_777_777)

        try service.pin(evidence, at: pinnedAt)
        let restored = IdentityPinningService(connectionID: connectionID, secureStore: store)

        #expect(restored.pin?.identityID == evidence.instance.id)
        #expect(restored.pin?.identityKey == evidence.instance.identityKey)
        #expect(restored.pin?.channelCA == evidence.instance.channelCA)
        #expect(restored.pin?.pinnedAt == pinnedAt)
        #expect(restored.pin?.matches(evidence) == true)
        #expect(store.savedAccounts == ["thane-identity-pin.connection-one"])
    }

    @Test("Identity pins are isolated between connection profiles")
    func connectionScopeIsolation() throws {
        let evidence = try IdentityTestFixture.evidence()
        let store = IdentityPinTestStore()
        let first = IdentityPinningService(connectionID: "connection-one", secureStore: store)
        try first.pin(evidence)

        let second = IdentityPinningService(connectionID: "connection-two", secureStore: store)

        #expect(first.pin?.matches(evidence) == true)
        #expect(second.pin == nil)
        #expect(store.value(account: "thane-identity-pin.connection-one") != nil)
        #expect(store.value(account: "thane-identity-pin.connection-two") == nil)
    }

    @Test("A failed scope load commits the new scope in a fail-closed state")
    func failedScopeChangeIsFailClosed() throws {
        let evidence = try IdentityTestFixture.evidence()
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        try service.pin(evidence)
        store.failingLoadAccounts.insert("thane-identity-pin.connection-two")

        #expect(throws: IdentityPinError.self) {
            try service.changeScope(to: "connection-two")
        }
        #expect(service.connectionID == "connection-two")
        #expect(service.pin == nil)
        #expect(service.lastError != nil)
        #expect(throws: IdentityPinError.self) {
            try service.pin(evidence)
        }
    }

    @Test("A legacy global pin migrates into the current connection profile")
    func legacyPinMigration() throws {
        let evidence = try IdentityTestFixture.evidence()
        let encoded = try JSONEncoder().encode(ThaneIdentityPin(evidence: evidence))
        let value = try #require(String(data: encoded, encoding: .utf8))
        let store = IdentityPinTestStore(values: [
            ConnectionSecurityScope.legacyIdentityPinAccount: value,
        ])

        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)

        #expect(service.pin?.matches(evidence) == true)
        #expect(store.value(account: "thane-identity-pin.connection-one") == value)
        #expect(store.value(account: ConnectionSecurityScope.legacyIdentityPinAccount) == nil)
    }

    @Test("Display-name changes do not change stable identity")
    func displayNameDoesNotAffectMatch() throws {
        let evidence = try IdentityTestFixture.evidence()
        let renamed = replacingInstance(
            in: evidence,
            with: ThaneInstanceIdentity(
                id: evidence.instance.id,
                name: "renamed",
                identityKey: evidence.instance.identityKey,
                channelCA: evidence.instance.channelCA
            )
        )

        #expect(ThaneIdentityPin(evidence: evidence).matches(renamed))
    }

    @Test("Additive certificate metadata does not change pinned continuity")
    func certificateMetadataDoesNotAffectMatch() throws {
        let evidence = try IdentityTestFixture.evidence()
        let legacyEvidence = replacingInstance(
            in: evidence,
            with: ThaneInstanceIdentity(
                id: evidence.instance.id,
                name: evidence.instance.name,
                identityKey: evidence.instance.identityKey,
                channelCA: PublicIdentityMaterial(
                    algorithm: evidence.instance.channelCA.algorithm,
                    fingerprint: evidence.instance.channelCA.fingerprint
                )
            )
        )

        #expect(ThaneIdentityPin(evidence: legacyEvidence).matches(evidence))
        #expect(ThaneIdentityPin(evidence: evidence).matches(legacyEvidence))
    }

    @Test("Each stable identity field participates in matching")
    func stableMaterialMismatch() throws {
        let evidence = try IdentityTestFixture.evidence()
        let pin = ThaneIdentityPin(evidence: evidence)

        let otherID = replacingInstance(
            in: evidence,
            with: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:other",
                name: evidence.instance.name,
                identityKey: evidence.instance.identityKey,
                channelCA: evidence.instance.channelCA
            )
        )
        let otherKey = replacingInstance(
            in: evidence,
            with: ThaneInstanceIdentity(
                id: evidence.instance.id,
                name: evidence.instance.name,
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:other"
                ),
                channelCA: evidence.instance.channelCA
            )
        )
        let otherCA = replacingInstance(
            in: evidence,
            with: ThaneInstanceIdentity(
                id: evidence.instance.id,
                name: evidence.instance.name,
                identityKey: evidence.instance.identityKey,
                channelCA: PublicIdentityMaterial(
                    algorithm: "x509-ed25519",
                    fingerprint: "SHA256:other"
                )
            )
        )

        #expect(!pin.matches(otherID))
        #expect(!pin.matches(otherKey))
        #expect(!pin.matches(otherCA))
    }

    @Test("Continuity states distinguish first trust, match, stale, unavailable, and mismatch")
    func continuityStates() throws {
        let evidence = try IdentityTestFixture.evidence()
        let pin = ThaneIdentityPin(evidence: evidence)
        let freshNow = evidence.observedAt.addingTimeInterval(60)
        let staleNow = evidence.observedAt.addingTimeInterval(
            IdentityContinuityState.maximumEvidenceAge + 1
        )
        let mismatch = replacingInstance(
            in: evidence,
            with: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:other",
                name: "other",
                identityKey: evidence.instance.identityKey,
                channelCA: evidence.instance.channelCA
            )
        )

        #expect(IdentityContinuityState.evaluate(pin: nil, evidence: nil) == .notPinned)
        #expect(IdentityContinuityState.evaluate(pin: nil, evidence: evidence) == .presented)
        #expect(
            IdentityContinuityState.evaluate(pin: pin, evidence: evidence, now: freshNow) == .matching
        )
        #expect(
            IdentityContinuityState.evaluate(pin: pin, evidence: evidence, now: staleNow) == .stale
        )
        #expect(IdentityContinuityState.evaluate(pin: pin, evidence: nil) == .unavailable)
        #expect(IdentityContinuityState.evaluate(pin: pin, evidence: mismatch) == .mismatch)
        #expect(IdentityContinuityState.matching.permitsPrivateDelivery)
        #expect(!IdentityContinuityState.stale.permitsPrivateDelivery)
        #expect(!IdentityContinuityState.mismatch.permitsPrivateDelivery)
        #expect(!IdentityContinuityState.unavailable.permitsPrivateDelivery)
    }

    @Test("A different identity requires an explicit forget")
    func explicitForget() throws {
        let evidence = try IdentityTestFixture.evidence()
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        try service.pin(evidence)

        #expect(throws: IdentityPinError.alreadyPinned) {
            try service.pin(evidence)
        }

        try service.forget()
        #expect(service.pin == nil)
        #expect(store.deletedAccounts.contains("thane-identity-pin.connection-one"))
    }

    @Test("An unreadable saved pin fails closed until explicitly forgotten")
    func corruptPinFailsClosed() throws {
        let evidence = try IdentityTestFixture.evidence()
        let store = IdentityPinTestStore(
            values: ["thane-identity-pin": "not-json"]
        )
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)

        #expect(service.pin == nil)
        #expect(service.lastError != nil)
        #expect(throws: IdentityPinError.corruptPin) {
            try service.pin(evidence)
        }

        try service.forget()
        try service.pin(evidence)
        #expect(service.pin?.matches(evidence) == true)
    }

    // MARK: - Stored evidence for background delivery

    /// A process launched by Core Location has no scene and cannot fetch
    /// identity evidence. The stored snapshot is what lets it decide whether
    /// it may deliver at all.
    @Test("Stored evidence is restored when it matches the pin and is inside the ceiling")
    func storedEvidenceRestores() throws {
        let evidence = try IdentityTestFixture.evidence(observedAt: Date())
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        try service.pin(evidence)
        service.storeEvidence(evidence, from: endpoint)

        let relaunched = IdentityPinningService(connectionID: connectionID, secureStore: store)
        let restored = try #require(relaunched.restoredEvidence(for: endpoint))
        #expect(restored.evidence.instance.id == evidence.instance.id)
        #expect(store.savedAccounts.contains("thane-identity-evidence.connection-one"))
    }

    /// The ceiling is the whole of what this relaxation costs: an identity
    /// rotated or revoked goes unnoticed by a phone that never reaches the
    /// foreground, but only for this long.
    @Test("Stored evidence past the ceiling stops authorising delivery")
    func storedEvidenceExpires() throws {
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        let old = try IdentityTestFixture.evidence(observedAt: Date())
        try service.pin(old)
        // Aged by when this device verified it, which is the only clock the
        // ceiling is allowed to trust.
        service.storeEvidence(
            old,
            from: endpoint,
            verifiedAt: Date().addingTimeInterval(-IdentityContinuityState.maximumStoredEvidenceAge - 60)
        )

        #expect(service.restoredEvidence(for: endpoint) == nil)
    }

    /// Continuity is *not* relaxed. Only recency is. A snapshot that does not
    /// match the pin authorises nothing, so this phone cannot be pointed at a
    /// different Thane by anything held on the device.
    /// The ceiling has to be measured by a clock this device controls. If it
    /// ran from the server-supplied observedAt, a future timestamp would
    /// produce a negative age, pass any bound, and authorise delivery until
    /// that timestamp plus the ceiling.
    @Test("A future server timestamp cannot extend the ceiling")
    func futureObservedAtCannotExtendTheCeiling() throws {
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        let farFuture = try IdentityTestFixture.evidence(
            observedAt: Date().addingTimeInterval(365 * 24 * 60 * 60)
        )
        try service.pin(farFuture)

        // Verified long ago by this device, whatever the server claims.
        service.storeEvidence(
            farFuture,
            from: endpoint,
            verifiedAt: Date().addingTimeInterval(-IdentityContinuityState.maximumStoredEvidenceAge - 60)
        )

        #expect(service.restoredEvidence(for: endpoint) == nil)
    }

    @Test("Stored evidence that does not match the pin is refused")
    func storedEvidenceMustMatchPin() throws {
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        let pinned = try IdentityTestFixture.evidence(observedAt: Date())
        try service.pin(pinned)

        let impostor = replacingInstance(
            in: pinned,
            with: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:someone-else",
                name: pinned.instance.name,
                identityKey: pinned.instance.identityKey,
                channelCA: pinned.instance.channelCA
            )
        )
        service.storeEvidence(impostor, from: endpoint)

        #expect(service.restoredEvidence(for: endpoint) == nil)
    }

    /// The pin binds the snapshot to an identity; nothing binds it to an
    /// address, and the connection ID scoping its Keychain account survives an
    /// edit to the server URL. Without the endpoint check, evidence verified
    /// against one Thane would authorise delivery to whatever URL was typed in
    /// next, as soon as a refresh against that URL failed.
    @Test("Stored evidence does not authorise a different endpoint")
    func storedEvidenceIsBoundToItsEndpoint() throws {
        let evidence = try IdentityTestFixture.evidence(observedAt: Date())
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        try service.pin(evidence)
        service.storeEvidence(evidence, from: endpoint)

        let elsewhere = try #require(URL(string: "https://someone-else.example"))
        #expect(service.restoredEvidence(for: elsewhere) == nil)
        #expect(service.restoredEvidence(for: nil) == nil)
        #expect(service.restoredEvidence(for: endpoint) != nil)
    }

    @Test("Forgetting an agent removes its stored evidence")
    func forgettingRemovesStoredEvidence() throws {
        let evidence = try IdentityTestFixture.evidence(observedAt: Date())
        let store = IdentityPinTestStore()
        let service = IdentityPinningService(connectionID: connectionID, secureStore: store)
        try service.pin(evidence)
        service.storeEvidence(evidence, from: endpoint)
        #expect(service.restoredEvidence(for: endpoint) != nil)

        try service.forget()

        let relaunched = IdentityPinningService(connectionID: connectionID, secureStore: store)
        #expect(relaunched.restoredEvidence(for: endpoint) == nil)
        #expect(store.value(account: "thane-identity-evidence.connection-one") == nil)
    }

    private func replacingInstance(
        in evidence: ThaneIdentityEvidence,
        with instance: ThaneInstanceIdentity
    ) -> ThaneIdentityEvidence {
        ThaneIdentityEvidence(
            schemaVersion: evidence.schemaVersion,
            observedAt: evidence.observedAt,
            instance: instance,
            core: evidence.core
        )
    }
}

@MainActor
private final class IdentityPinTestStore: CredentialStoring {
    private var values: [String: String]
    private(set) var savedAccounts: [String] = []
    private(set) var deletedAccounts: [String] = []
    var failingLoadAccounts: Set<String> = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) {
        values[account] = value
        savedAccounts.append(account)
    }

    func load(account: String) throws -> String? {
        if failingLoadAccounts.contains(account) {
            throw IdentityPinTestStoreError.loadFailed
        }
        return values[account]
    }

    func delete(account: String) {
        values[account] = nil
        deletedAccounts.append(account)
    }

    func value(account: String) -> String? {
        values[account]
    }
}

private enum IdentityPinTestStoreError: Error {
    case loadFailed
}
