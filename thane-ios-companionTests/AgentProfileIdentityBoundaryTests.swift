import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("App identity boundary")
@MainActor
struct AgentProfileIdentityBoundaryTests {
    @Test("Photos authorization cannot enable sharing for a replacement counterparty")
    func photosAuthorizationCannotCrossCounterparties() async throws {
        let firstEvidence = try IdentityTestFixture.freshEvidence()
        let secondEvidence = ThaneIdentityEvidence(
            schemaVersion: firstEvidence.schemaVersion,
            observedAt: firstEvidence.observedAt,
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:replacement",
                name: "replacement",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:replacement"
                ),
                channelCA: firstEvidence.instance.channelCA
            ),
            core: firstEvidence.core
        )
        let photoLibrary = DeferredAuthorizationPhotoLibrary()
        let fixture = try AppIdentityFixture(
            evidence: firstEvidence,
            pinnedEvidence: firstEvidence,
            photoLibrary: photoLibrary
        )
        defer { fixture.cleanup() }

        let authorization = Task { @MainActor in
            await fixture.profile.setPhotoSharing(enabled: true)
        }
        try await waitUntil { photoLibrary.hasPendingAuthorization }
        await fixture.profile.forgetThane()
        fixture.profile.pin(secondEvidence)
        photoLibrary.resumeAuthorization(.full)
        await authorization.value

        #expect(fixture.profile.sharingPreferences.counterpartyID == secondEvidence.instance.id)
        #expect(fixture.profile.sharingPreferences.photosEnabled == false)
    }

    @Test("First connection waits for an explicit identity pin")
    func firstConnectionWaitsForPin() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(evidence: evidence)
        defer { fixture.cleanup() }

        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        #expect(fixture.profile.identityContinuity == .presented)
        #expect(fixture.profile.connection.state == .disconnected)
        #expect(fixture.profile.connectionSettings.isEnabled)

        fixture.profile.pinPresentedIdentity()

        #expect(fixture.profile.identityPinning.pin?.matches(evidence) == true)
        #expect(fixture.profile.identityContinuity.permitsPrivateDelivery)
        #expect(fixture.profile.sharingPreferences.counterpartyID == evidence.instance.id)
        #expect(fixture.profile.connection.state != .disconnected)
        fixture.profile.disconnect()
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

        fixture.profile.pin(evidence)

        #expect(fixture.profile.identityPinning.pin?.matches(evidence) == true)
        #expect(fixture.profile.identityContinuity == .unavailable)
        #expect(fixture.profile.sharingPreferences.counterpartyID == evidence.instance.id)
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

        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        #expect(fixture.profile.identityContinuity == .mismatch)
        #expect(fixture.profile.connection.state == .disconnected)
        #expect(
            fixture.profile.displayedError
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

        fixture.profile.activate()

        #expect(identityService.isRefreshing)
        #expect(fixture.profile.identityContinuity == .unavailable)
        #expect(fixture.profile.connection.state == .disconnected)
        try await waitUntil { !identityService.isRefreshing }
        #expect(fixture.profile.connection.state == .disconnected)
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
        fixture.profile.connection.handleAuthenticationFailure("Invalid token")

        fixture.profile.activate()

        #expect(fixture.profile.displayedError == "Authentication failed: Invalid token")
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

        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        #expect(fixture.profile.identityContinuity == .stale)
        #expect(!fixture.profile.identityContinuity.permitsPrivateDelivery)
        #expect(fixture.profile.connection.state == .disconnected)
        #expect(
            fixture.profile.displayedError
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

        fixture.profile.connection.onReconnectValidationRequested?()

        #expect(fixture.profile.identityService.isRefreshing)
        #expect(fixture.profile.connection.state == .disconnected)
        try await fixture.waitForIdentityRefresh()
        #expect(fixture.profile.identityContinuity == .matching)
        #expect(fixture.profile.connection.state != .disconnected)
    }

    @Test("Forgetting a pin suspends but preserves that counterparty's sharing policy")
    func forgettingPinSuspendsScopedSharing() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }

        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()
        fixture.profile.setSystemCategory(.regional, enabled: true)
        fixture.profile.sharingPreferences.photosEnabled = true
        #expect(fixture.profile.sharingPreferences.regionalEnabled)
        #expect(fixture.profile.sharingPreferences.photosEnabled)

        await fixture.profile.forgetThane()

        #expect(fixture.profile.identityPinning.pin == nil)
        #expect(fixture.profile.sharingPreferences.counterpartyID == nil)
        #expect(fixture.profile.sharingPreferences.hasEnabledData == false)

        fixture.profile.pinPresentedIdentity()
        #expect(fixture.profile.sharingPreferences.counterpartyID == evidence.instance.id)
        #expect(fixture.profile.sharingPreferences.regionalEnabled)
        #expect(fixture.profile.sharingPreferences.photosEnabled)
        fixture.profile.disconnect()
    }

    @Test("Forgetting a pin hides its inbox and re-pinning restores it")
    func forgettingPinSuspendsScopedInbox() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let record = InboxRecord(
            id: "suggestion-1",
            counterpartyID: evidence.instance.id,
            kind: .suggestion,
            title: "A useful suggestion",
            summary: "There is a quiet opening this afternoon.",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        try fixture.profile.inboxStore.upsert(record)
        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()

        await fixture.profile.forgetThane()

        #expect(fixture.profile.inboxStore.boundCounterpartyID == nil)
        #expect(fixture.profile.inboxStore.records.isEmpty)

        fixture.profile.pinPresentedIdentity()

        #expect(
            fixture.profile.inboxStore.boundCounterpartyID
                == evidence.instance.id
        )
        #expect(fixture.profile.inboxStore.records == [record])
        fixture.profile.disconnect()
    }

    @Test("Re-pinning the same counterparty preserves its pairwise client identity")
    func sameCounterpartyPreservesPairwiseIdentity() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let clientID = fixture.profile.connectionSettings.pairwiseClientID

        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()
        await fixture.profile.forgetThane()
        fixture.profile.pinPresentedIdentity()

        #expect(fixture.profile.connectionSettings.pairwiseClientID == clientID)
        #expect(
            fixture.profile.connectionSettings.pairwiseCounterpartyID
                == evidence.instance.id
        )
        fixture.profile.disconnect()
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
        let clientID = fixture.profile.connectionSettings.pairwiseClientID

        fixture.profile.connectUsingCurrentValues()
        try await fixture.waitForIdentityRefresh()
        #expect(fixture.profile.identityContinuity == .mismatch)
        await fixture.profile.forgetThane()
        fixture.profile.pinPresentedIdentity()

        #expect(fixture.profile.connectionSettings.pairwiseClientID != clientID)
        #expect(
            fixture.profile.connectionSettings.pairwiseCounterpartyID
                == otherEvidence.instance.id
        )
        fixture.profile.disconnect()
    }

    @Test("Removing a connection deletes its identity-scoped local state")
    func removingConnectionDeletesScopedState() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let profileID = fixture.profile.id
        let originalConnectionID = fixture.profile.connectionSettings.connectionID
        let originalClientID = fixture.profile.connectionSettings.pairwiseClientID

        fixture.profile.setSystemCategory(.regional, enabled: true)
        fixture.profile.sharingPreferences.photosEnabled = true
        await fixture.profile.removeConnection()

        #expect(!fixture.profile.hasConnectionConfiguration)
        #expect(fixture.profile.id == profileID)
        #expect(fixture.profile.connectionSettings.connectionID != originalConnectionID)
        #expect(fixture.profile.connectionSettings.pairwiseClientID != originalClientID)
        #expect(
            fixture.profile.identityPinning.connectionID
                == fixture.profile.connectionSettings.connectionID
        )
        #expect(fixture.profile.connectionSettings.urlString.isEmpty)
        #expect(fixture.profile.tokenInput.isEmpty)
        #expect(fixture.profile.identityPinning.pin == nil)
        #expect(fixture.profile.sharingPreferences.counterpartyID == nil)

        fixture.profile.sharingPreferences.scope(to: evidence.instance.id)
        #expect(fixture.profile.sharingPreferences.hasEnabledData == false)
    }

    @Test("Removing after forgetting a pin still deletes scoped sharing")
    func removingAfterForgetDeletesScopedSharing() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }

        fixture.profile.setSystemCategory(.regional, enabled: true)
        fixture.profile.sharingPreferences.photosEnabled = true
        await fixture.profile.forgetThane()
        await fixture.profile.removeConnection()

        fixture.profile.sharingPreferences.scope(to: evidence.instance.id)
        #expect(fixture.profile.sharingPreferences.hasEnabledData == false)
    }

    @Test("Removing after forgetting a pin deletes its preserved inbox")
    func removingAfterForgetDeletesScopedInbox() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let profileID = fixture.profile.id
        try fixture.profile.inboxStore.upsert(
            InboxRecord(
                id: "suggestion-1",
                counterpartyID: evidence.instance.id,
                kind: .suggestion,
                title: "A useful suggestion",
                summary: "There is a quiet opening this afternoon.",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )

        await fixture.profile.forgetThane()
        await fixture.profile.removeConnection()

        let reloaded = fixture.inboxStore(
            profileID: profileID,
            counterpartyID: evidence.instance.id
        )
        #expect(reloaded.records.isEmpty)
        #expect(reloaded.lastError == nil)
    }

    @Test("A token deletion failure leaves the configured profile retryable")
    func tokenDeletionFailureLeavesConfigurationRetryable() async throws {
        let evidence = try IdentityTestFixture.freshEvidence()
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence
        )
        defer { fixture.cleanup() }
        let originalConnectionID = fixture.profile.connectionSettings.connectionID
        fixture.secureStore.failingDeleteAccounts.insert(
            fixture.profile.connectionSettings.securityScope.tokenAccount
        )

        await fixture.profile.removeConnection()

        #expect(fixture.profile.connectionSettings.connectionID == originalConnectionID)
        #expect(!fixture.profile.connectionSettings.urlString.isEmpty)
        #expect(fixture.profile.tokenInput == "secret")
        #expect(fixture.profile.identityPinning.pin?.matches(evidence) == true)
        #expect(fixture.profile.displayedError != nil)
    }

    private static func backgroundFix() -> LocationSnapshot {
        LocationSnapshot(
            capturedAt: "2026-09-01T12:00:00Z",
            locationTimestamp: "2026-09-01T12:00:00Z",
            latitude: 41.88,
            longitude: -87.63,
            altitudeMeters: nil,
            ellipsoidalAltitudeMeters: nil,
            horizontalAccuracyMeters: 5,
            verticalAccuracyMeters: nil,
            speedMetersPerSecond: nil,
            speedAccuracyMetersPerSecond: nil,
            courseDegrees: nil,
            courseAccuracyDegrees: nil,
            floor: nil,
            authorization: "always",
            accuracyAuthorization: "full",
            simulatedBySoftware: false,
            producedByAccessory: false
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for app identity state")
    }

    // MARK: - Background delivery on stored evidence

    /// The outcome the whole change exists for: a process launched by Core
    /// Location, with no scene and therefore no way to fetch fresh evidence,
    /// still delivers. Before this it recorded and waited for a foreground
    /// launch that might be days away.
    @Test("A relaunch with stored evidence delivers without a live fetch")
    func storedEvidenceAuthorisesBackgroundDelivery() async throws {
        let evidence = try IdentityTestFixture.evidence(observedAt: Date())
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence,
            storedEvidence: evidence,
            connectionEnabled: true
        )
        defer { fixture.cleanup() }

        // No activate(), no scene, no identity refresh — a background launch.
        fixture.profile.observationPublisher.publishLocation(Self.backgroundFix())

        try await waitUntil { fixture.uploader.callCount == 1 }
        #expect(fixture.uploader.callCount == 1)
    }

    /// The ceiling is load-bearing, not decorative.
    @Test("A relaunch with expired stored evidence records but does not deliver")
    func expiredStoredEvidenceBlocksBackgroundDelivery() async throws {
        let evidence = try IdentityTestFixture.evidence(observedAt: Date())
        let expired = try IdentityTestFixture.evidence(
            observedAt: Date().addingTimeInterval(-IdentityContinuityState.maximumStoredEvidenceAge - 60)
        )
        let fixture = try AppIdentityFixture(
            evidence: evidence,
            pinnedEvidence: evidence,
            storedEvidence: expired,
            connectionEnabled: true
        )
        defer { fixture.cleanup() }

        fixture.profile.observationPublisher.publishLocation(Self.backgroundFix())

        try await waitUntil { fixture.profile.observationPublisher.pendingCount == 1 }
        // Settle before asserting the negative. Enqueue calls flush on its own
        // tail, so checking the moment the event lands would pass whether or
        // not delivery was blocked — the same race that let the old
        // capture-gate test assert the wrong thing and stay green.
        try await Task.sleep(for: .milliseconds(200))
        #expect(fixture.uploader.callCount == 0)
        #expect(fixture.profile.observationPublisher.pendingCount == 1)
    }

}

@MainActor
private final class AppIdentityFixture {
    let profile: AgentProfile
    let secureStore: AppIdentitySecureStore
    let uploader: AppIdentityUploader

    private let suite: String
    private let defaults: UserDefaults
    private let directoryURL: URL

    init(
        evidence: ThaneIdentityEvidence,
        pinnedEvidence: ThaneIdentityEvidence? = nil,
        storedEvidence: ThaneIdentityEvidence? = nil,
        identityService: IdentityService? = nil,
        connectionEnabled: Bool = false,
        photoLibrary: (any PhotoLibraryReading)? = nil
    ) throws {
        suite = "AgentProfileIdentityBoundaryTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let secureStore = AppIdentitySecureStore(values: [
            ConnectionSecurityScope.legacyTokenAccount: "secret",
        ])
        self.secureStore = secureStore
        let settings = ConnectionSettings(
            profileID: "profile-one",
            defaults: defaults,
            credentialStore: secureStore
        )
        let pinning = IdentityPinningService(
            connectionID: settings.connectionID,
            secureStore: secureStore
        )
        if let pinnedEvidence {
            try pinning.pin(pinnedEvidence)
        }
        // Seeded before AgentProfile is built, so its init sees exactly what a
        // process launched by Core Location sees: a pin and a stored snapshot
        // in the Keychain, and no live evidence anywhere.
        if let storedEvidence {
            pinning.storeEvidence(storedEvidence)
        }
        settings.urlString = "https://thane.example"
        settings.isEnabled = connectionEnabled
        let uploader = AppIdentityUploader()
        self.uploader = uploader
        let publisher = ObservationPublisher(
            outbox: ObservationOutbox(
                fileURL: directoryURL.appendingPathComponent("outbox.json")
            ),
            uploader: uploader
        )
        let inboxStore = InboxStore(
            profileID: settings.profileID,
            storageDirectoryURL: directoryURL
        )
        profile = AgentProfile(
            connectionSettings: settings,
            sharingPreferences: SharingPreferences(defaults: defaults),
            observationPublisher: publisher,
            identityService: identityService ?? IdentityService(
                fetcher: AppIdentityFetcher(evidence: evidence)
            ),
            identityPinning: pinning,
            inboxStore: inboxStore,
            photoLibrary: photoLibrary
        )
    }

    func inboxStore(profileID: String, counterpartyID: String) -> InboxStore {
        let store = InboxStore(
            profileID: profileID,
            storageDirectoryURL: directoryURL
        )
        store.scope(to: counterpartyID)
        return store
    }

    func waitForIdentityRefresh() async throws {
        for _ in 0..<100 {
            if !profile.identityService.isRefreshing,
               profile.presentedIdentity != nil {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for identity evidence")
    }

    func cleanup() {
        profile.disconnect()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

@MainActor
private final class DeferredAuthorizationPhotoLibrary: PhotoLibraryReading {
    var authorizationStatus: PhotoAuthorizationState = .notDetermined
    private(set) var hasPendingAuthorization = false
    private var authorizationContinuation: CheckedContinuation<PhotoAuthorizationState, Never>?

    func requestAuthorization() async -> PhotoAuthorizationState {
        hasPendingAuthorization = true
        return await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
    }

    func fetchRecentPhotos(
        limit _: Int,
        embeddedMetadataLimit _: Int
    ) async throws -> [PhotoLibraryAsset] {
        []
    }

    func resumeAuthorization(_ status: PhotoAuthorizationState) {
        authorizationStatus = status
        hasPendingAuthorization = false
        let continuation = authorizationContinuation
        authorizationContinuation = nil
        continuation?.resume(returning: status)
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
    private(set) var callCount = 0

    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult {
        callCount += 1
        return ObservationIngestResult(stored: batch.events.count, ignored: 0, receivedAt: Date())
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
