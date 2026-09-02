import Foundation

@Observable
@MainActor
final class ConnectionSettings {
    private nonisolated static let urlKey = "connection.baseURL"
    private nonisolated static let legacyClientIDKey = "connection.clientID"
    private nonisolated static let pairwiseClientIDKeyPrefix = "connection.pairwiseClientID."
    private nonisolated static let pairwiseCounterpartyKeyPrefix = "connection.pairwiseCounterpartyID."
    private nonisolated static let profileIDKey = "connection.profileID"
    private nonisolated static let connectionIDKey = "connection.configurationID"
    private nonisolated static let enabledKey = "connection.enabled"

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring

    var urlString: String {
        didSet { defaults.set(urlString, forKey: Self.urlKey) }
    }
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    private(set) var profileID: String
    private(set) var connectionID: String
    private(set) var pairwiseClientID: String
    private(set) var pairwiseCounterpartyID: String?

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        urlString = defaults.string(forKey: Self.urlKey) ?? ""
        isEnabled = defaults.bool(forKey: Self.enabledKey)

        let resolvedConnectionID: String
        if let existing = defaults.string(forKey: Self.connectionIDKey),
           !existing.isEmpty {
            resolvedConnectionID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.connectionIDKey)
            resolvedConnectionID = generated
        }
        connectionID = resolvedConnectionID
        let resolvedProfileID: String
        if let existing = defaults.string(forKey: Self.profileIDKey),
           !existing.isEmpty {
            resolvedProfileID = existing
        } else {
            // Existing single-profile installs already use the durable
            // connection ID as their aggregate identity. Preserve that value
            // so profile-scoped storage migrates without changing ownership.
            resolvedProfileID = resolvedConnectionID
            defaults.set(resolvedProfileID, forKey: Self.profileIDKey)
        }
        profileID = resolvedProfileID

        let scopedClientIDKey = Self.pairwiseClientIDKey(for: resolvedConnectionID)
        if let existing = defaults.string(forKey: scopedClientIDKey),
           !existing.isEmpty {
            pairwiseClientID = existing
        } else if let legacy = defaults.string(forKey: Self.legacyClientIDKey),
                  !legacy.isEmpty {
            defaults.set(legacy, forKey: scopedClientIDKey)
            pairwiseClientID = legacy
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: scopedClientIDKey)
            pairwiseClientID = generated
        }
        defaults.removeObject(forKey: Self.legacyClientIDKey)
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
            try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
            return scoped
        }
        guard let legacy = try credentialStore.load(
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
        try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
    }

    func deleteToken() throws {
        try credentialStore.delete(account: securityScope.tokenAccount)
        try credentialStore.delete(account: ConnectionSecurityScope.legacyTokenAccount)
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
        defaults.set(connectionID, forKey: Self.connectionIDKey)
        pairwiseClientID = UUID().uuidString
        defaults.set(pairwiseClientID, forKey: Self.pairwiseClientIDKey(for: connectionID))
        pairwiseCounterpartyID = nil
    }

    private nonisolated static func pairwiseClientIDKey(for connectionID: String) -> String {
        pairwiseClientIDKeyPrefix + connectionID
    }

    private nonisolated static func pairwiseCounterpartyKey(for connectionID: String) -> String {
        pairwiseCounterpartyKeyPrefix + connectionID
    }
}
