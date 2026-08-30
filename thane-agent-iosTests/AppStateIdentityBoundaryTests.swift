import Foundation
import Testing
@testable import thane_agent_ios

@Suite("App identity boundary")
@MainActor
struct AppStateIdentityBoundaryTests {
    @Test("First connection waits for an explicit identity pin")
    func firstConnectionWaitsForPin() async throws {
        let evidence = try IdentityTestFixture.evidence()
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
        #expect(fixture.appState.connection.state != .disconnected)
        fixture.appState.disconnect()
    }

    @Test("A presented identity mismatch blocks connection establishment")
    func mismatchBlocksConnection() async throws {
        let pinnedEvidence = try IdentityTestFixture.evidence()
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
                == "The presented Thane identity does not match this iPhone's pin. Private delivery is blocked."
        )
    }
}

@MainActor
private final class AppIdentityFixture {
    let appState: AppState

    private let suite: String
    private let defaults: UserDefaults
    private let directoryURL: URL

    init(
        evidence: ThaneIdentityEvidence,
        pinnedEvidence: ThaneIdentityEvidence? = nil
    ) throws {
        suite = "AppStateIdentityBoundaryTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let tokenStore = AppIdentitySecureStore(values: ["thane-api-token": "secret"])
        let pinStore = AppIdentitySecureStore()
        let pinning = IdentityPinningService(secureStore: pinStore)
        if let pinnedEvidence {
            try pinning.pin(pinnedEvidence)
        }
        let settings = ConnectionSettings(defaults: defaults, credentialStore: tokenStore)
        settings.urlString = "https://thane.example"
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
            identityService: IdentityService(
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
    let evidence: ThaneIdentityEvidence

    init(evidence: ThaneIdentityEvidence) {
        self.evidence = evidence
    }

    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        evidence
    }
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

    init(values: [String: String] = [:]) {
        self.values = values
    }

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
    }
}
