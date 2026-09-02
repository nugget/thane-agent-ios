import Foundation
import Testing
@testable import thane_agent_ios

@Suite("App identity boundary")
@MainActor
struct AppStateIdentityBoundaryTests {
    @Test("First connection waits for an explicit identity pin")
    func firstConnectionWaitsForPin() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(evidence: evidence)
        defer { fixture.cleanup() }

        fixture.appState.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        #expect(fixture.appState.identityContinuity == .presented)
        #expect(fixture.appState.connection.state == .disconnected)
        #expect(fixture.appState.connectionSettings.isEnabled)

        fixture.appState.pinPresentedIdentity()

        #expect(fixture.appState.identityPinning.pin?.matches(evidence) == true)
        #expect(fixture.appState.identityContinuity.permitsPrivateDelivery)
        #expect(fixture.appState.sharingPreferences.counterpartyID == evidence.instance.id)
        #expect(fixture.appState.connection.state != .disconnected)
        fixture.appState.disconnect()
    }

    @Test("Pinning from an evidence screen pins that exact evidence")
    func pinningUsesSuppliedEvidence() throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let otherEvidence = ThaneIdentityEvidence(
            schemaVersion: evidence.schemaVersion,
            observedAt: evidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:other",
                name: "other",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:other"
                ),
                channelCA: evidence.instance.channelCA
            ),
            core: evidence.core
        )
        let fixture = try AppIdentityFixture(evidence: otherEvidence)
        defer { fixture.cleanup() }

        fixture.appState.pin(evidence)

        #expect(fixture.appState.identityPinning.pin?.matches(evidence) == true)
        #expect(fixture.appState.identityContinuity == .unavailable)
        #expect(fixture.appState.sharingPreferences.counterpartyID == evidence.instance.id)
    }

    @Test("A presented identity mismatch blocks connection establishment")
    func mismatchBlocksConnection() async throws {
        let pinnedEvidence = try IdentityTestFixture.freshEvidence()
        let mismatchedEvidence = ThaneIdentityEvidence(
            schemaVersion: pinnedEvidence.schemaVersion,
            observedAt: pinnedEvidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:different",
                name: "different",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:different"
                ),
                channelCA: pinnedEvidence.instance.channelCA
            ),
            core: pinnedEvidence.core
        )
        let fixture = try AppIdentityFixture(
            evidence: mismatchedEvidence,
            pinnedEvidence: pinnedEvidence
        )
        defer { fixture.cleanup() }

        fixture.appState.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        #expect(fixture.appState.identityContinuity == .mismatch)
        #expect(fixture.appState.connection.state == .disconnected)
        #expect(
            fixture.appState.displayedError
                == "The presented identity does not match pocket's pin on this iPhone. Private delivery is blocked."
        )
    }

    @Test("Activation waits for fresh identity evidence before reconnecting")
    func activationWaitsForFreshEvidence() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fetcher = AppIdentityFetcher(evidence: evidence)
        let identityService = IdentityService(fetcher: fetcher)
        let baseURL = try #require(URL(string: "https://thane.example"))
        identityService.refresh(from: baseURL, token: "secret")
        try await waitUntil { !identityService.isRefreshing }
        #expect(identityService.evidence(for: baseURL) == evidence)

        fetcher.result = .failure(AppIdentityTestError.expectedFailure)
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence,
            identityService: identityService,
            connectionEnabled: true
        )
        defer { fixture.cleanup() }

        fixture.appState.activate()

        #expect(identityService.isRefreshing)
        #expect(fixture.appState.identityContinuity == .unavailable)
        #expect(fixture.appState.connection.state == .disconnected)
        try await waitUntil { !identityService.isRefreshing }
        #expect(fixture.appState.connection.state == .disconnected)
    }

    @Test("Foreground activation preserves the last connection error")
    func activationPreservesLastConnectionError() throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence,
            connectionEnabled: true
        )
        defer { fixture.cleanup() }
        fixture.appState.connection.handleAuthenticationFailure("Invalid token")

        fixture.appState.activate()

        #expect(fixture.appState.displayedError == "Authentication failed: Invalid token")
    }

    @Test("Stale identity evidence blocks private delivery")
    func staleEvidenceBlocksPrivateDelivery() async throws {
        let evidence = try IdentityTestFixture.evidence(
            observedAt: Date().addingTimeInterval(
                -IdentityContinuityState.maximumEvidenceAge - 1
            )
        )
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }

        fixture.appState.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        #expect(fixture.appState.identityContinuity == .stale)
        #expect(!fixture.appState.identityContinuity.permitsPrivateDelivery)
        #expect(fixture.appState.connection.state == .disconnected)
        #expect(
            fixture.appState.displayedError
                == "Identity evidence is more than 15 minutes old. Refresh it before private delivery resumes."
        )
    }

    @Test("A reconnect request refreshes identity before transport resumes")
    func reconnectRequestRefreshesIdentity() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence,
            connectionEnabled: true
        )
        defer { fixture.cleanup() }

        fixture.appState.connection.onReconnectValidationRequested?()

        #expect(fixture.appState.identityService.isRefreshing)
        #expect(fixture.appState.connection.state == .disconnected)
        try await fixture.waitForIdentityRefresh()
        #expect(fixture.appState.identityContinuity == .matching)
        #expect(fixture.appState.connection.state != .disconnected)
    }

    @Test("Forgetting a pin suspends but preserves that counterparty's sharing policy")
    func forgettingPinSuspendsScopedSharing() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }

        fixture.appState.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()
        fixture.appState.setSystemCategory(.regional, enabled: true)
        #expect(fixture.appState.sharingPreferences.regionalEnabled)

        await fixture.appState.forgetThane()

        #expect(fixture.appState.identityPinning.pin == nil)
        #expect(fixture.appState.sharingPreferences.counterpartyID == nil)
        #expect(fixture.appState.sharingPreferences.hasEnabledData == false)

        fixture.appState.pinPresentedIdentity()
        #expect(fixture.appState.sharingPreferences.counterpartyID == evidence.instance.id)
        #expect(fixture.appState.sharingPreferences.regionalEnabled)
        fixture.appState.disconnect()
    }

    @Test("Re-pinning the same counterparty preserves its pairwise client identity")
    func sameCounterpartyPreservesPairwiseIdentity() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let clientID = fixture.appState.connectionSettings.pairwiseClientID

        fixture.appState.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()
        await fixture.appState.forgetThane()
        fixture.appState.pinPresentedIdentity()

        #expect(fixture.appState.connectionSettings.pairwiseClientID == clientID)
        #expect(
            fixture.appState.connectionSettings.pairwiseCounterpartyID
                == evidence.instance.id
        )
        fixture.appState.disconnect()
    }

    @Test("Rebinding a profile to a different counterparty rotates its pairwise client identity")
    func differentCounterpartyRotatesPairwiseIdentity() async throws {
        let pinnedEvidence = try IdentityTestFixture.freshEvidence()
        let otherEvidence = ThaneIdentityEvidence(
            schemaVersion: pinnedEvidence.schemaVersion,
            observedAt: pinnedEvidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:other",
                name: "other",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:other"
                ),
                channelCA: pinnedEvidence.instance.channelCA
            ),
            core: pinnedEvidence.core
        )
        let fixture = try AppIdentityFixture(
            evidence: otherEvidence,
            pinnedEvidence: pinnedEvidence
        )
        defer { fixture.cleanup() }
        let clientID = fixture.appState.connectionSettings.pairwiseClientID

        fixture.appState.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()
        #expect(fixture.appState.identityContinuity == .mismatch)
        await fixture.appState.forgetThane()
        fixture.appState.pinPresentedIdentity()

        #expect(fixture.appState.connectionSettings.pairwiseClientID != clientID)
        #expect(
            fixture.appState.connectionSettings.pairwiseCounterpartyID
                == otherEvidence.instance.id
        )
        fixture.appState.disconnect()
    }

    @Test("Removing a connection deletes its identity-scoped local state")
    func removingConnectionDeletesScopedState() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let originalConnectionID = fixture.appState.connectionSettings.connectionID
        let originalClientID = fixture.appState.connectionSettings.pairwiseClientID

        fixture.appState.setSystemCategory(.regional, enabled: true)
        await fixture.appState.removeConnection()

        #expect(fixture.appState.configuredConnections.isEmpty)
        #expect(fixture.appState.connectionSettings.connectionID != originalConnectionID)
        #expect(fixture.appState.connectionSettings.pairwiseClientID != originalClientID)
        #expect(
            fixture.appState.identityPinning.connectionID
                == fixture.appState.connectionSettings.connectionID
        )
        #expect(fixture.appState.connectionSettings.urlString.isEmpty)
        #expect(fixture.appState.tokenInput.isEmpty)
        #expect(fixture.appState.identityPinning.pin == nil)
        #expect(fixture.appState.sharingPreferences.counterpartyID == nil)

        fixture.appState.sharingPreferences.scope(to: evidence.instance.id)
        #expect(fixture.appState.sharingPreferences.hasEnabledData == false)
    }

    @Test("Removing after forgetting a pin still deletes scoped sharing")
    func removingAfterForgetDeletesScopedSharing() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }

        fixture.appState.setSystemCategory(.regional, enabled: true)
        await fixture.appState.forgetThane()
        await fixture.appState.removeConnection()

        fixture.appState.sharingPreferences.scope(to: evidence.instance.id)
        #expect(fixture.appState.sharingPreferences.hasEnabledData == false)
    }

    @Test("A token deletion failure leaves the configured profile retryable")
    func tokenDeletionFailureLeavesConfigurationRetryable() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let originalConnectionID = fixture.appState.connectionSettings.connectionID
        fixture.secureStore.failingDeleteAccounts.insert(
            fixture.appState.connectionSettings.securityScope.tokenAccount
        )

        await fixture.appState.removeConnection()

        #expect(fixture.appState.connectionSettings.connectionID == originalConnectionID)
        #expect(!fixture.appState.connectionSettings.urlString.isEmpty)
        #expect(fixture.appState.tokenInput == "secret")
        #expect(fixture.appState.identityPinning.pin?.matches(evidence) == true)
        #expect(fixture.appState.displayedError != nil)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for app identity state")
    }
}

@MainActor
private final class AppIdentityFixture {
    let appState: AppState
    let secureStore: AppIdentitySecureStore

    private let suite: String
    private let defaults: UserDefaults
    private let directoryURL: URL

    init(
        evidence: ThaneIdentityEvidence,
        pinnedEvidence: ThaneIdentityEvidence? = nil,
        identityService: IdentityService? = nil,
        connectionEnabled: Bool = false
    ) throws {
        suite = "AppStateIdentityBoundaryTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let secureStore = AppIdentitySecureStore(values: [
            ConnectionSecurityScope.legacyTokenAccount: "secret",
        ])
        self.secureStore = secureStore
        let settings = ConnectionSettings(defaults: defaults, credentialStore: secureStore)
        let pinning = IdentityPinningService(
            connectionID: settings.connectionID,
            secureStore: secureStore
        )
        if let pinnedEvidence {
            try pinning.pin(pinnedEvidence)
        }
        settings.urlString = "https://thane.example"
        settings.isEnabled = connectionEnabled
        let publisher = ObservationPublisher(
            outbox: ObservationOutbox(
                fileURL: directoryURL.appendingPathComponent("outbox.json")
            ),
            uploader: AppIdentityUploader()
        )
        appState = AppState(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            observationPublisher: publisher,
            identityService: identityService ?? IdentityService(
                fetcher: AppIdentityFetcher(evidence: evidence)
            ),
            identityPinning: pinning
        )
    }

    func waitForIdentityRefresh() async throws {
        for _ in 0..<100 {
            if !appState.identityService.isRefreshing,
               appState.presentedIdentity != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for identity evidence")
    }

    func cleanup() {
        appState.disconnect()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private final class AppIdentityFetcher: IdentityEvidenceFetching {
    var result: Result<ThaneIdentityEvidence, Error>

    init(evidence: ThaneIdentityEvidence) {
        result = .success(evidence)
    }

    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        try result.get()
    }
}

private enum AppIdentityTestError: Error {
    case expectedFailure
}

@MainActor
private final class AppIdentityUploader: ObservationUploading {
    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult {
        ObservationIngestResult(stored: batch.events.count, ignored: 0, receivedAt: Date())
    }
}

@MainActor
private final class AppIdentitySecureStore: CredentialStoring {
    private var values: [String: String]
    var failingDeleteAccounts: Set<String> = []

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) throws {
        if failingDeleteAccounts.contains(account) {
            throw AppIdentityTestError.expectedFailure
        }
        values[account] = nil
    }
}
