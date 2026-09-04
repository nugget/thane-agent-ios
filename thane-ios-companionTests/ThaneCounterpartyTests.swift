import Testing
@testable import ThaneIOSCompanion

@Suite("Thane counterparty")
struct ThaneCounterpartyTests {
    @Test("Pinned identity is the configured counterparty identity")
    func pinnedIdentity() throws {
        let evidence = try IdentityTestFixture.evidence()
        let pin = ThaneIdentityPin(evidence: evidence)

        let counterparty = ThaneCounterparty(pin: pin)

        #expect(counterparty.id == evidence.instance.id)
        #expect(counterparty.displayName == evidence.instance.name)
        #expect(counterparty.shortFingerprint == evidence.instance.shortFingerprint)
        #expect(counterparty.trust == .pinned)
    }

    @Test("Matching current evidence refreshes a pinned counterparty's display name")
    func matchingEvidenceRefreshesPinnedDisplayName() throws {
        let evidence = try IdentityTestFixture.evidence()
        let pin = ThaneIdentityPin(evidence: evidence)
        let renamedEvidence = ThaneIdentityEvidence(
            schemaVersion: evidence.schemaVersion,
            observedAt: evidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: evidence.instance.id,
                name: "Renamed Thane",
                identityKey: evidence.instance.identityKey,
                channelCA: evidence.instance.channelCA
            ),
            core: evidence.core
        )

        let counterparty = ThaneCounterparty(
            pin: pin,
            presentedEvidence: renamedEvidence
        )

        #expect(counterparty.displayName == "Renamed Thane")
        #expect(counterparty.trust == .pinned)
    }

    @Test("Mismatched evidence cannot rename a pinned counterparty")
    func mismatchedEvidenceKeepsPinnedDisplayName() throws {
        let evidence = try IdentityTestFixture.evidence()
        let pin = ThaneIdentityPin(evidence: evidence)
        let mismatchedEvidence = ThaneIdentityEvidence(
            schemaVersion: evidence.schemaVersion,
            observedAt: evidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:different",
                name: "Untrusted Name",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:different"
                ),
                channelCA: evidence.instance.channelCA
            ),
            core: evidence.core
        )

        let counterparty = ThaneCounterparty(
            pin: pin,
            presentedEvidence: mismatchedEvidence
        )

        #expect(counterparty.displayName == pin.nameAtPinning)
        #expect(counterparty.trust == .pinned)
    }

    @Test("Presented identity remains visibly provisional")
    func presentedIdentity() throws {
        let evidence = try IdentityTestFixture.evidence()

        let counterparty = ThaneCounterparty(evidence: evidence)

        #expect(counterparty.id == evidence.instance.id)
        #expect(counterparty.trust == .presented)
    }
}
