import Foundation

nonisolated struct ConnectionSecurityScope: Equatable, Sendable {
    static let legacyTokenAccount = "thane-api-token"
    static let legacyIdentityPinAccount = "thane-identity-pin"

    let connectionID: String

    var tokenAccount: String {
        "thane-api-token.\(connectionID)"
    }

    var identityPinAccount: String {
        "thane-identity-pin.\(connectionID)"
    }
}
