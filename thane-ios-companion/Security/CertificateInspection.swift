import CryptoKit
import Foundation
import Security

nonisolated struct TransportCertificate: Equatable, Identifiable, Sendable {
    let position: Int
    let subject: String
    let issuer: String?
    let sha256Fingerprint: String
    let serialNumber: String?
    let notValidBefore: Date?
    let notValidAfter: Date?

    var id: String { "\(position):\(sha256Fingerprint)" }

    static func fingerprint(for certificateData: Data) -> String {
        let digest = Data(SHA256.hash(data: certificateData))
        return "SHA256:\(digest.base64EncodedString().replacingOccurrences(of: "=", with: ""))"
    }
}

nonisolated enum CertificateChainInspector {
    static func inspect(_ trust: SecTrust) -> [TransportCertificate] {
        guard let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate] else {
            return []
        }
        let subjects = certificates.map(subjectSummary)

        return certificates.enumerated().map { position, certificate in
            let issuer = position + 1 < subjects.count ? subjects[position + 1] : nil
            return TransportCertificate(
                position: position,
                subject: subjects[position],
                issuer: issuer,
                sha256Fingerprint: TransportCertificate.fingerprint(
                    for: SecCertificateCopyData(certificate) as Data
                ),
                serialNumber: serialNumber(certificate),
                notValidBefore: SecCertificateCopyNotValidBeforeDate(certificate) as Date?,
                notValidAfter: SecCertificateCopyNotValidAfterDate(certificate) as Date?
            )
        }
    }

    private static func subjectSummary(_ certificate: SecCertificate) -> String {
        SecCertificateCopySubjectSummary(certificate) as String? ?? "Unnamed certificate"
    }

    private static func serialNumber(_ certificate: SecCertificate) -> String? {
        guard let data = SecCertificateCopySerialNumberData(certificate, nil) as Data? else {
            return nil
        }
        return data.map { String(format: "%02X", $0) }.joined()
    }
}

nonisolated final class ServerTrustObserver: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let onServerTrust: @Sendable ([TransportCertificate]) -> Void

    init(onServerTrust: @escaping @Sendable ([TransportCertificate]) -> Void) {
        self.onServerTrust = onServerTrust
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            onServerTrust(CertificateChainInspector.inspect(trust))
        }

        // Inspection must not become a parallel trust policy. URLSession still
        // performs Apple's normal hostname and certificate validation.
        completionHandler(.performDefaultHandling, nil)
    }
}
