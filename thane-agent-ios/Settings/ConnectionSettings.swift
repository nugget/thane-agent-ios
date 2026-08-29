import Foundation

@Observable
@MainActor
final class ConnectionSettings {
    private nonisolated static let urlKey = "connection.baseURL"
    private nonisolated static let clientIDKey = "connection.clientID"
    private nonisolated static let enabledKey = "connection.enabled"
    private nonisolated static let tokenAccount = "thane-api-token"

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring

    var urlString: String {
        didSet { defaults.set(urlString, forKey: Self.urlKey) }
    }
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }
    let clientID: String

    init(
        defaults: UserDefaults = .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        urlString = defaults.string(forKey: Self.urlKey) ?? ""
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        if let existing = defaults.string(forKey: Self.clientIDKey) {
            clientID = existing
        } else {
            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.clientIDKey)
            clientID = generated
        }
    }

    var serverURL: URL? {
        ServerAddress.parse(urlString)
    }

    func storedToken() throws -> String? {
        try credentialStore.load(account: Self.tokenAccount)
    }

    func saveToken(_ token: String) throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try credentialStore.save(trimmed, account: Self.tokenAccount)
    }

    func deleteToken() throws {
        try credentialStore.delete(account: Self.tokenAccount)
    }
}
