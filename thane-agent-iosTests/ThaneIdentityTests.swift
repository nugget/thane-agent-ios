import Foundation
import Testing

@testable import thane_agent_ios

@Suite("Thane identity evidence")
struct ThaneIdentityTests {
    @Test("Schema-one evidence preserves identity and provenance semantics")
    func decodesEvidence() throws {
        let evidence = try IdentityTestFixture.evidence()

        #expect(evidence.schemaVersion == 1)
        #expect(evidence.instance.name == "pocket")
        #expect(evidence.instance.shortFingerprint == "8N6XQd…lKfJNo")
        #expect(evidence.instance.channelCA.certificate?.subject == "CN=pocket Thane Channel CA")
        #expect(evidence.instance.channelCA.certificate?.serialNumber == "4F3A19D270EBC1")
        #expect(evidence.instance.channelCA.certificate?.isCA == true)
        #expect(evidence.instance.channelCA.certificate?.selfSigned == true)
        #expect(
            evidence.instance.channelCA.certificate?.notAfter
                == ObservationCoding.date(from: "2036-07-01T12:00:00Z")
        )
        #expect(evidence.core.birth.timeAssurance == "signed_claim")
        #expect(evidence.core.birth.anchor == "operator")
        #expect(evidence.core.currentCommit.shortened == "fedcba9…cba98")
        #expect(evidence.core.head.worktreeClean)
        #expect(evidence.core.verification.admission.isVerified)
        #expect(!evidence.core.verification.head.isVerified)
        #expect(evidence.observedAt == ObservationCoding.date(from: "2026-08-30T19:22:31.123Z"))
    }

    @Test("Certificate metadata is additive for older identity evidence")
    func legacyMaterialCompatibility() throws {
        let material = try ThaneIdentityCoding.decoder().decode(
            PublicIdentityMaterial.self,
            from: Data(
                #"{"algorithm":"x509-ed25519","fingerprint":"SHA256:legacy"}"#.utf8
            )
        )

        #expect(material.algorithm == "x509-ed25519")
        #expect(material.fingerprint == "SHA256:legacy")
        #expect(material.certificate == nil)
    }

    @Test("Identity marks are deterministic and horizontally symmetric")
    func identityMark() {
        let first = ThaneIdentityMarkDescriptor(identityID: "thane:ed25519:SHA256:first")
        let repeated = ThaneIdentityMarkDescriptor(identityID: "thane:ed25519:SHA256:first")
        let other = ThaneIdentityMarkDescriptor(identityID: "thane:ed25519:SHA256:other")

        #expect(first == repeated)
        #expect(first != other)
        #expect(first.cells.count == 25)
        for row in 0..<5 {
            #expect(first.cells[row * 5] == first.cells[row * 5 + 4])
            #expect(first.cells[row * 5 + 1] == first.cells[row * 5 + 3])
        }
        #expect(first.cells[12])
    }
}
