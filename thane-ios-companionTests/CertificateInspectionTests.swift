import Foundation
import Testing

@testable import ThaneIOSCompanion

@Suite("Certificate inspection")
struct CertificateInspectionTests {
    @Test("Certificate fingerprints use the identity-compatible SHA-256 format")
    func fingerprintFormat() {
        let fingerprint = TransportCertificate.fingerprint(for: Data("abc".utf8))

        #expect(fingerprint == "SHA256:ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0")
    }
}
