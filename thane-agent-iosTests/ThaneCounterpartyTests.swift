import Testing
@testable import thane_agent_ios

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

    @Test("Presented identity remains visibly provisional")
    func presentedIdentity() throws {
        let evidence = try IdentityTestFixture.evidence()

        let counterparty = ThaneCounterparty(evidence: evidence)

        #expect(counterparty.id == evidence.instance.id)
        #expect(counterparty.trust == .presented)
    }
}
