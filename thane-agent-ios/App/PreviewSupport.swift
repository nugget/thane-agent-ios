import Foundation

#if DEBUG
@MainActor
enum PreviewFixtures {
    static let endpoint = URL(string: "https://aimee.example.com")!

    static var evidence: ThaneIdentityEvidence {
        ThaneIdentityEvidence(
            schemaVersion: 1,
            observedAt: Date(),
            instance: ThaneInstanceIdentity(
                id: "thane:ed25519:SHA256:aimee-preview-identity",
                name: "Aimée",
                identityKey: PublicIdentityMaterial(
                    algorithm: "ed25519",
                    fingerprint: "SHA256:9ma2YWrpPj8BHsaxW5BDxW6yVtQDk5uJEFcmZn6pVxQ"
                ),
                channelCA: PublicIdentityMaterial(
                    algorithm: "x509-ed25519",
                    fingerprint: "SHA256:3rA4gWmCwY2fYcNbfvnqgTtvrMjEaRVmdtnUYo6t5hI",
                    certificate: channelCertificate
                )
            ),
            core: CoreIdentityEvidence(
                birth: CoreBirthEvidence(
                    commit: GitObjectID(
                        algorithm: "sha1",
                        oid: "0123456789abcdef0123456789abcdef01234567"
                    ),
                    assertedAt: Date(timeIntervalSince1970: 1_751_371_200),
                    timeAssurance: "signed_claim",
                    anchor: "operator"
                ),
                currentCommit: GitObjectID(
                    algorithm: "sha1",
                    oid: "fedcba9876543210fedcba9876543210fedcba98"
                ),
                head: CoreHeadEvidence(
                    worktreeClean: true,
                    trustFileChangeCount: 0
                ),
                verification: CoreVerificationEvidence(
                    admission: IdentityCheckEvidence(
                        status: "verified",
                        detail: "The signed birth commit is admitted by the configured seed policy."
                    ),
                    head: IdentityCheckEvidence(
                        status: "verified",
                        detail: "The active core descends from the admitted birth commit."
                    )
                )
            )
        )
    }

    static var counterparty: ThaneCounterparty {
        ThaneCounterparty(evidence: evidence)
    }

    static var pin: ThaneIdentityPin {
        ThaneIdentityPin(
            evidence: evidence,
            pinnedAt: Date().addingTimeInterval(-21 * 24 * 60 * 60)
        )
    }

    static let channelCertificate = X509CertificateEvidence(
        subject: "CN=Aimée Thane Channel CA",
        issuer: "CN=Aimée Thane Channel CA",
        serialNumber: "6A1D2C3B4E5F6071",
        notBefore: Date(timeIntervalSince1970: 1_751_371_200),
        notAfter: Date(timeIntervalSince1970: 2_382_854_400),
        isCA: true,
        selfSigned: true,
        publicKeyAlgorithm: "Ed25519",
        signatureAlgorithm: "Ed25519"
    )

    static let transportCertificates = [
        TransportCertificate(
            position: 0,
            subject: "aimee.example.com",
            issuer: "Example Intermediate CA 1",
            sha256Fingerprint: "SHA256:8tq3XaDkv7ZQhHqvgspRw4oaPoBcTgLkrV5dS9W6fYQ",
            serialNumber: "039A71D2B65F12C8",
            notValidBefore: Date(timeIntervalSince1970: 1_767_225_600),
            notValidAfter: Date(timeIntervalSince1970: 1_798_761_600)
        ),
        TransportCertificate(
            position: 1,
            subject: "Example Intermediate CA 1",
            issuer: "Example Root CA",
            sha256Fingerprint: "SHA256:P9VxgUk6cbYtKHN3sB4YjeQdLmaWvF8nZpC2rT7oE1I",
            serialNumber: "14C09B2E7A38D451",
            notValidBefore: Date(timeIntervalSince1970: 1_577_836_800),
            notValidAfter: Date(timeIntervalSince1970: 2_051_222_400)
        ),
        TransportCertificate(
            position: 2,
            subject: "Example Root CA",
            issuer: nil,
            sha256Fingerprint: "SHA256:W3mK8vQa1Fb7jH2rZ6tNc4pYs9GdL5uXe0BfCiRkM7A",
            serialNumber: "01",
            notValidBefore: Date(timeIntervalSince1970: 1_420_070_400),
            notValidAfter: Date(timeIntervalSince1970: 2_209_032_000)
        ),
    ]

    static func appState() -> AppState {
        let defaults = isolatedDefaults()
        let credentialStore = PreviewCredentialStore()
        let connectionSettings = ConnectionSettings(
            profileID: "preview-profile",
            defaults: defaults,
            credentialStore: credentialStore
        )
        connectionSettings.urlString = endpoint.absoluteString
        connectionSettings.isEnabled = true

        let token = "preview-token"
        do {
            try connectionSettings.saveToken(token)
        } catch {
            preconditionFailure("Could not prepare preview credentials: \(error)")
        }

        let identity = evidence
        let identityPinning = IdentityPinningService(
            connectionID: connectionSettings.connectionID,
            secureStore: credentialStore
        )
        do {
            try identityPinning.pin(
                identity,
                at: Date().addingTimeInterval(-21 * 24 * 60 * 60)
            )
        } catch {
            preconditionFailure("Could not prepare preview identity: \(error)")
        }

        let sharingPreferences = SharingPreferences(defaults: defaults)
        let identityService = IdentityService(
            fetcher: PreviewIdentityFetcher(evidence: identity)
        )
        let inboxStore = InboxStore(
            profileID: connectionSettings.profileID,
            storageDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "info.nugget.thane-agent-ios.preview.\(UUID().uuidString)",
                    isDirectory: true
                )
        )
        let profile = AgentProfile(
            connectionSettings: connectionSettings,
            sharingPreferences: sharingPreferences,
            identityService: identityService,
            identityPinning: identityPinning,
            conversationStore: ConversationStore(summaries: [
                ConversationSummary(
                    counterpartyID: identity.instance.id,
                    conversationID: "planning",
                    title: "Weekend planning",
                    latestMessagePreview: "I found two openings that fit your calendar.",
                    updatedAt: Date(),
                    unreadCount: 2
                ),
                ConversationSummary(
                    counterpartyID: identity.instance.id,
                    conversationID: "garage",
                    title: "Elise telemetry",
                    latestMessagePreview: "The oil-pressure trace is ready to inspect.",
                    updatedAt: Date().addingTimeInterval(-2_700)
                ),
            ]),
            inboxStore: inboxStore
        )
        do {
            try inboxStore.upsert(
                InboxRecord(
                    id: "journal-evening",
                    counterpartyID: identity.instance.id,
                    kind: .suggestion,
                    title: "A good moment to journal",
                    summary: "Your afternoon opened up. Want to capture a few notes before dinner?",
                    createdAt: Date().addingTimeInterval(-480)
                )
            )
            try inboxStore.upsert(
                InboxRecord(
                    id: "elise-trace",
                    counterpartyID: identity.instance.id,
                    kind: .conversation,
                    title: "Telemetry trace is ready",
                    summary: "The oil-pressure trace from the last drive is ready to inspect.",
                    createdAt: Date().addingTimeInterval(-2_700),
                    isRead: true,
                    relatedConversationID: "garage"
                )
            )
        } catch {
            preconditionFailure("Could not prepare preview inbox: \(error)")
        }
        let appState = AppState(
            appPreferences: AppPreferences(defaults: defaults),
            profiles: [profile]
        )

        sharingPreferences.setEnabled(true, for: .regional)
        sharingPreferences.setEnabled(true, for: .device)
        sharingPreferences.locationEnabled = true
        identityService.refresh(from: endpoint, token: token)
        return appState
    }

    private static func isolatedDefaults() -> UserDefaults {
        let suiteName = "info.nugget.thane-agent-ios.preview.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not create isolated preview defaults")
        }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private struct PreviewIdentityFetcher: IdentityEvidenceFetching {
    let evidence: ThaneIdentityEvidence

    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        evidence
    }
}

@MainActor
private final class PreviewCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]

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
#endif
