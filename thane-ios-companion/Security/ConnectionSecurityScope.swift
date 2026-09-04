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

    /// The last identity evidence this connection verified. Stored so a
    /// process launched into the background — which has no scene, and so no
    /// way to fetch fresh evidence — can still establish that it is talking
    /// to the Thane the operator pinned.
    var identityEvidenceAccount: String {
        "thane-identity-evidence.\(connectionID)"
    }
}
