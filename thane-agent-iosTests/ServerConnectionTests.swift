import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Server connection")
@MainActor
struct ServerConnectionTests {
    @Test("Connection establishment flushes registered follow-up work")
    func connectionEstablishedCallback() {
        let connection = ServerConnection()
        var callbackCount = 0
        connection.onConnected = {
            callbackCount += 1
        }

        connection.handleConnectionEstablished()

        #expect(connection.state == .connected)
        #expect(connection.lastError == nil)
        #expect(callbackCount == 1)
    }

    @Test("Certificate chain observed before establishment is published on connection")
    func certificateChainObservedBeforeEstablishment() {
        let connection = ServerConnection()
        let chain = Self.certificateChain()

        connection.recordTransportCertificateChain(chain)
        #expect(connection.transportCertificateChain.isEmpty)

        connection.handleConnectionEstablished()

        #expect(connection.transportCertificateChain == chain)
        #expect(connection.transportCertificateCapturedAt != nil)
    }

    @Test("Certificate chain observed after establishment is published immediately")
    func certificateChainObservedAfterEstablishment() {
        let connection = ServerConnection()
        let chain = Self.certificateChain()

        connection.handleConnectionEstablished()
        connection.recordTransportCertificateChain(chain)

        #expect(connection.transportCertificateChain == chain)
        #expect(connection.transportCertificateCapturedAt != nil)
    }

    @Test("Disconnect retains the last authenticated certificate evidence")
    func disconnectRetainsCertificateEvidence() {
        let connection = ServerConnection()
        let chain = Self.certificateChain()
        connection.recordTransportCertificateChain(chain)
        connection.handleConnectionEstablished()
        let capturedAt = connection.transportCertificateCapturedAt

        connection.disconnect()

        #expect(connection.transportCertificateChain == chain)
        #expect(connection.transportCertificateCapturedAt == capturedAt)
    }

    @Test("Refreshing identity for a different endpoint clears retained transport evidence")
    func endpointChangeClearsCertificateEvidence() throws {
        let firstEndpoint = try #require(URL(string: "https://first.example"))
        let secondEndpoint = try #require(URL(string: "https://second.example"))
        let connection = ServerConnection()
        let chain = Self.certificateChain()
        connection.handleConnectionEstablished()
        connection.recordTransportCertificateChain(chain, endpoint: firstEndpoint)

        connection.prepareForIdentityRefresh(from: firstEndpoint)
        #expect(connection.transportCertificateChain == chain)

        connection.prepareForIdentityRefresh(from: secondEndpoint)
        #expect(connection.transportCertificateChain.isEmpty)
        #expect(connection.transportCertificateCapturedAt == nil)
        #expect(connection.transportCertificateEndpoint == nil)
    }

    @Test("Disconnect retains the last connection error until success")
    func disconnectRetainsConnectionError() {
        let connection = ServerConnection()
        connection.handleAuthenticationFailure("Invalid token")

        connection.disconnect()

        #expect(connection.lastError == "Authentication failed: Invalid token")

        connection.handleConnectionEstablished()
        #expect(connection.lastError == nil)
    }

    @Test("Explicit diagnostic reset clears retained evidence and errors")
    func explicitDiagnosticReset() {
        let connection = ServerConnection()
        connection.recordTransportCertificateChain(Self.certificateChain())
        connection.handleConnectionEstablished()
        connection.handleAuthenticationFailure("Invalid token")

        connection.clearRetainedDiagnostics()

        #expect(connection.transportCertificateChain.isEmpty)
        #expect(connection.transportCertificateCapturedAt == nil)
        #expect(connection.transportCertificateEndpoint == nil)
        #expect(connection.lastError == nil)
    }

    @Test("Authentication failure stops reconnecting and reports the error")
    func authenticationFailureIsTerminal() {
        let connection = ServerConnection()
        var callbackCount = 0
        connection.onAuthenticationFailure = {
            callbackCount += 1
        }

        connection.handleAuthenticationFailure("Invalid token")

        #expect(connection.state == .disconnected)
        #expect(connection.lastError == "Authentication failed: Invalid token")
        #expect(callbackCount == 1)
    }

    @Test("Authentication failure disables persisted auto-connect")
    func authenticationFailureDisablesAutoConnect() throws {
        let suite = "ServerConnectionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ConnectionSettings(
            defaults: defaults,
            credentialStore: AuthenticationCredentialStore()
        )
        settings.isEnabled = true
        let appState = AppState(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            identityPinning: IdentityPinningService(
                connectionID: settings.connectionID,
                secureStore: AuthenticationCredentialStore()
            )
        )

        appState.connection.handleAuthenticationFailure("Expired token")

        #expect(settings.isEnabled == false)
        #expect(appState.connection.state == .disconnected)
        #expect(appState.displayedError == "Authentication failed: Expired token")
    }

    private static func certificateChain() -> [TransportCertificate] {
        [
            TransportCertificate(
                position: 0,
                subject: "thane.example",
                issuer: "Test CA",
                sha256Fingerprint: "SHA256:test",
                serialNumber: "01",
                notValidBefore: nil,
                notValidAfter: nil
            ),
        ]
    }
}

@MainActor
private final class AuthenticationCredentialStore: CredentialStoring {
    func save(_ value: String, account: String) {}

    func load(account: String) -> String? {
        nil
    }

    func delete(account: String) {}
}
