import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Identity pinning")
@MainActor
struct IdentityPinningTests {
    private let connectionID = "connection-one"

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
        #expect(IdentityContinuityState.stale.permitsPrivateDelivery)
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

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) {
        values[account] = value
        savedAccounts.append(account)
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
        deletedAccounts.append(account)
    }

    func value(account: String) -> String? {
        values[account]
    }
}
