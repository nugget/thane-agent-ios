import Foundation

@Observable
@MainActor
final class ConnectionSettings {
    // Pre-scoping global keys. The two identity-bearing keys are deliberately
    // retained after adoption: they are the recovery anchor that lets an
    // upgrading installation re-derive the same profile and connection IDs if
    // the roster is ever lost. See AgentProfileRoster.
    nonisolated static let legacyURLKey = "connection.baseURL"
    nonisolated static let legacyEnabledKey = "connection.enabled"
    nonisolated static let legacyClientIDKey = "connection.clientID"
    nonisolated static let legacyProfileIDKey = "connection.profileID"
    nonisolated static let legacyConnectionIDKey = "connection.configurationID"

    // Profile-scoped keys. The "configurationID" suffix keeps its historical
    // spelling on purpose; renaming it in the same change as the re-scoping
    // would orphan every existing token and identity pin.
    private nonisolated static let scopedKeyPrefix = "agent."
    private nonisolated static let urlSuffix = "baseURL"
    private nonisolated static let enabledSuffix = "enabled"
    private nonisolated static let connectionIDSuffix = "configurationID"
    private nonisolated static let profileAnchorSuffix = "profileID"

    // Connection-scoped keys. These stay keyed by connection ID rather than
    // profile ID: removeConfiguration() rotates the connection ID to retire a
    // pairwise identity, and re-keying them by the never-rotating profile ID
    // would silently turn that rotation into a no-op.
    private nonisolated static let pairwiseClientIDKeyPrefix = "connection.pairwiseClientID."
    private nonisolated static let pairwiseCounterpartyKeyPrefix = "connection.pairwiseCounterpartyID."

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring

    let profileID: String

    var urlString: String {
        didSet { defaults.set(urlString, forKey: Self.urlKey(for: profileID)) }
    }
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey(for: profileID)) }
    }
    private(set) var connectionID: String
    private(set) var pairwiseClientID: String
    private(set) var pairwiseCounterpartyID: String?

    init(
        profileID: String,
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        precondition(!profileID.isEmpty, "A connection profile requires a stable profile ID.")
        self.profileID = profileID
        self.defaults = defaults
        self.credentialStore = credentialStore

        urlString = defaults.string(forKey: Self.urlKey(for: profileID)) ?? ""
        isEnabled = defaults.bool(forKey: Self.enabledKey(for: profileID))

        let resolvedConnectionID: String
        if let existing = defaults.string(forKey: Self.connectionIDKey(for: profileID)),
           !existing.isEmpty {
            resolvedConnectionID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.connectionIDKey(for: profileID))
            resolvedConnectionID = generated
        }
        connectionID = resolvedConnectionID
        // The anchor is written only now: it is the signal that recovery uses to
        // rebuild a lost roster, and it must never be visible before the scoped
        // connection ID it vouches for.
        Self.writeProfileAnchor(profileID: profileID, in: defaults)

        let scopedClientIDKey = Self.pairwiseClientIDKey(for: resolvedConnectionID)
        if let existing = defaults.string(forKey: scopedClientIDKey),
           !existing.isEmpty {
            pairwiseClientID = existing
        } else if let legacy = Self.legacyClientID(ownedBy: profileID, in: defaults) {
            // Persist the scoped copy before consuming the only other record of
            // this identity, so an interruption cannot lose it outright.
            defaults.set(legacy, forKey: scopedClientIDKey)
            defaults.removeObject(forKey: Self.legacyClientIDKey)
            pairwiseClientID = legacy
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: scopedClientIDKey)
            pairwiseClientID = generated
        }
        pairwiseCounterpartyID = defaults.string(
            forKey: Self.pairwiseCounterpartyKey(for: resolvedConnectionID)
        )
    }

    var serverURL: URL? {
        ServerAddress.parse(urlString)
    }

    var securityScope: ConnectionSecurityScope {
        ConnectionSecurityScope(connectionID: connectionID)
    }

    func storedToken() throws -> String? {
        if let scoped = try credentialStore.load(account: securityScope.tokenAccount) {
            if Self.ownsLegacyIdentity(profileID: profileID, in: defaults) {
                try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
            }
            return scoped
        }
        guard Self.ownsLegacyIdentity(profileID: profileID, in: defaults),
              let legacy = try credentialStore.load(
                  account: ConnectionSecurityScope.legacyTokenAccount
              ) else {
            return nil
        }
        try credentialStore.save(legacy, account: securityScope.tokenAccount)
        try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
        return legacy
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try credentialStore.save(trimmed, account: securityScope.tokenAccount)
        if Self.ownsLegacyIdentity(profileID: profileID, in: defaults) {
            try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
        }
    }

    func deleteToken() throws {
        try credentialStore.delete(account: securityScope.tokenAccount)
        if Self.ownsLegacyIdentity(profileID: profileID, in: defaults) {
            try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
        }
    }

    @discardableResult
    func bindPairwiseClientID(to counterpartyID: String) -> Bool {
        guard !counterpartyID.isEmpty else { return false }
        if pairwiseCounterpartyID == counterpartyID {
            return false
        }

        let didRotate = pairwiseCounterpartyID != nil
        if didRotate {
            pairwiseClientID = UUID().uuidString
            defaults.set(
                pairwiseClientID,
                forKey: Self.pairwiseClientIDKey(for: connectionID)
            )
        }
        pairwiseCounterpartyID = counterpartyID
        defaults.set(
            counterpartyID,
            forKey: Self.pairwiseCounterpartyKey(for: connectionID)
        )
        return didRotate
    }

    func removeConfiguration() {
        let oldConnectionID = connectionID
        urlString = ""
        isEnabled = false
        defaults.removeObject(forKey: Self.pairwiseClientIDKey(for: oldConnectionID))
        defaults.removeObject(forKey: Self.pairwiseCounterpartyKey(for: oldConnectionID))

        connectionID = UUID().uuidString
        defaults.set(connectionID, forKey: Self.connectionIDKey(for: profileID))
        pairwiseClientID = UUID().uuidString
        defaults.set(pairwiseClientID, forKey: Self.pairwiseClientIDKey(for: connectionID))
        pairwiseCounterpartyID = nil
    }

    // MARK: - Profile-scoped key construction

    nonisolated static func urlKey(for profileID: String) -> String {
        scopedKey(profileID, urlSuffix)
    }

    nonisolated static func enabledKey(for profileID: String) -> String {
        scopedKey(profileID, enabledSuffix)
    }

    nonisolated static func connectionIDKey(for profileID: String) -> String {
        scopedKey(profileID, connectionIDSuffix)
    }

    nonisolated static func profileAnchorKey(for profileID: String) -> String {
        scopedKey(profileID, profileAnchorSuffix)
    }

    private nonisolated static func scopedKey(_ profileID: String, _ suffix: String) -> String {
        "\(scopedKeyPrefix)\(profileID).\(suffix)"
    }

    private nonisolated static func pairwiseClientIDKey(for connectionID: String) -> String {
        pairwiseClientIDKeyPrefix + connectionID
    }

    private nonisolated static func pairwiseCounterpartyKey(for connectionID: String) -> String {
        pairwiseCounterpartyKeyPrefix + connectionID
    }

    /// Recovers the profile ID from a self-describing anchor key, or nil when
    /// the key is not an anchor. Profile IDs never contain a period, so the
    /// middle segment is unambiguous.
    nonisolated static func profileID(fromAnchorKey key: String) -> String? {
        let suffix = ".\(profileAnchorSuffix)"
        guard key.hasPrefix(scopedKeyPrefix), key.hasSuffix(suffix) else { return nil }
        let middle = String(key.dropFirst(scopedKeyPrefix.count).dropLast(suffix.count))
        guard !middle.isEmpty, !middle.contains(".") else { return nil }
        return middle
    }

    nonisolated static func writeProfileAnchor(profileID: String, in defaults: UserDefaults) {
        defaults.set(profileID, forKey: profileAnchorKey(for: profileID))
    }

    // MARK: - Pre-scoping adoption

    /// Copies the pre-scoping global values into a profile's keyspace.
    ///
    /// Every copy is guarded on the destination being absent, and the two
    /// identity-bearing legacy keys are retained, so a crash at any point
    /// leaves the migration safe to re-run and re-derive identical values.
    nonisolated static func adoptLegacyValues(
        profileID: String,
        connectionID: String,
        in defaults: UserDefaults
    ) {
        if defaults.object(forKey: connectionIDKey(for: profileID)) == nil {
            defaults.set(connectionID, forKey: connectionIDKey(for: profileID))
        }
        if defaults.object(forKey: urlKey(for: profileID)) == nil,
           let legacyURL = defaults.string(forKey: legacyURLKey) {
            defaults.set(legacyURL, forKey: urlKey(for: profileID))
        }
        // Probed for presence rather than read as a Bool: materialising an
        // explicit false where the user had "never set" would silently gate
        // reconnect and observation delivery.
        if defaults.object(forKey: enabledKey(for: profileID)) == nil,
           defaults.object(forKey: legacyEnabledKey) != nil {
            defaults.set(defaults.bool(forKey: legacyEnabledKey), forKey: enabledKey(for: profileID))
        }

        // Only the non-identity-bearing sources are consumed. The profile ID
        // and connection ID keys stay put as the recovery anchor.
        defaults.removeObject(forKey: legacyURLKey)
        defaults.removeObject(forKey: legacyEnabledKey)

        // Written last, so an interrupted adoption leaves no anchor and the next
        // launch re-runs it against the retained legacy keys, re-deriving
        // identical IDs. An anchor published first would end recovery early and
        // let a fresh connection ID be minted over the existing token and pin.
        writeProfileAnchor(profileID: profileID, in: defaults)
    }

    /// True when this profile inherited the pre-scoping installation, and is
    /// therefore the sole legitimate claimant of the unscoped legacy Keychain
    /// accounts and client ID.
    ///
    /// Ownership is the first roster position: adoption always places the
    /// inherited profile there. Without a roster the profile is the only one
    /// that exists, so it owns anything left behind.
    private nonisolated static func ownsLegacyIdentity(
        profileID: String,
        in defaults: UserDefaults
    ) -> Bool {
        guard let roster = defaults.array(forKey: AgentProfileRoster.rosterKey) as? [String],
              let owner = roster.first(where: { !$0.isEmpty }) else {
            return true
        }
        return owner == profileID
    }

    /// Reads the pre-pairwise global client ID, but only for the profile that
    /// actually inherited it. Without this ownership check the first profile
    /// constructed would steal an identifier belonging to another.
    ///
    /// This only reads. Consuming the legacy key is the caller's job, after the
    /// scoped copy has been persisted.
    private nonisolated static func legacyClientID(
        ownedBy profileID: String,
        in defaults: UserDefaults
    ) -> String? {
        guard ownsLegacyIdentity(profileID: profileID, in: defaults),
              let legacy = defaults.string(forKey: legacyClientIDKey),
              !legacy.isEmpty else {
            return nil
        }
        return legacy
    }

    // MARK: - Erasure

    /// Erases every profile-scoped value, including the connection-scoped
    /// pairwise keys reachable through it. Callers must erase Keychain and
    /// on-disk storage first: the connection ID that names those Keychain
    /// accounts lives in the values this removes.
    nonisolated static func purgeScopedValues(profileID: String, in defaults: UserDefaults) {
        if let connectionID = defaults.string(forKey: connectionIDKey(for: profileID)),
           !connectionID.isEmpty {
            defaults.removeObject(forKey: pairwiseClientIDKey(for: connectionID))
            defaults.removeObject(forKey: pairwiseCounterpartyKey(for: connectionID))
        }
        defaults.removeObject(forKey: urlKey(for: profileID))
        defaults.removeObject(forKey: enabledKey(for: profileID))
        defaults.removeObject(forKey: connectionIDKey(for: profileID))
        defaults.removeObject(forKey: profileAnchorKey(for: profileID))
    }
}
