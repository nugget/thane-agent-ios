import CryptoKit
import Foundation

nonisolated struct ThaneIdentityEvidence: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let observedAt: Date
    let instance: ThaneInstanceIdentity
    let core: CoreIdentityEvidence

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case observedAt = "observed_at"
        case instance, core
    }
}

nonisolated struct ThaneInstanceIdentity: Codable, Equatable, Sendable {
    let id: String
    let name: String
    let identityKey: PublicIdentityMaterial
    let channelCA: PublicIdentityMaterial

    enum CodingKeys: String, CodingKey {
        case id, name
        case identityKey = "identity_key"
        case channelCA = "channel_ca"
    }

    var shortFingerprint: String {
        Self.shortened(identityKey.fingerprint)
    }

    private static func shortened(_ fingerprint: String) -> String {
        let value = fingerprint.hasPrefix("SHA256:")
            ? String(fingerprint.dropFirst("SHA256:".count))
            : fingerprint
        guard value.count > 12 else { return value }
        return "\(value.prefix(6))…\(value.suffix(6))"
    }
}

nonisolated struct PublicIdentityMaterial: Codable, Equatable, Sendable {
    let algorithm: String
    let fingerprint: String
}

nonisolated struct CoreIdentityEvidence: Codable, Equatable, Sendable {
    let birth: CoreBirthEvidence
    let currentCommit: GitObjectID
    let head: CoreHeadEvidence
    let verification: CoreVerificationEvidence

    enum CodingKeys: String, CodingKey {
        case birth, head, verification
        case currentCommit = "current_commit"
    }
}

nonisolated struct CoreBirthEvidence: Codable, Equatable, Sendable {
    let commit: GitObjectID
    let assertedAt: Date
    let timeAssurance: String
    let anchor: String

    enum CodingKeys: String, CodingKey {
        case commit, anchor
        case assertedAt = "asserted_at"
        case timeAssurance = "time_assurance"
    }
}

nonisolated struct GitObjectID: Codable, Equatable, Sendable {
    let algorithm: String
    let oid: String

    var shortened: String {
        guard oid.count > 12 else { return oid }
        return "\(oid.prefix(7))…\(oid.suffix(5))"
    }
}

nonisolated struct CoreHeadEvidence: Codable, Equatable, Sendable {
    let worktreeClean: Bool
    let trustFileChangeCount: Int

    enum CodingKeys: String, CodingKey {
        case worktreeClean = "worktree_clean"
        case trustFileChangeCount = "trust_file_change_count"
    }
}

nonisolated struct CoreVerificationEvidence: Codable, Equatable, Sendable {
    let admission: IdentityCheckEvidence
    let head: IdentityCheckEvidence
}

nonisolated struct IdentityCheckEvidence: Codable, Equatable, Sendable {
    let status: String
    let detail: String

    var isVerified: Bool { status == "verified" }
}

/// A deterministic visual companion to an identity fingerprint. This is a
/// recognition aid only; the fingerprint and its evidence remain authoritative.
nonisolated struct ThaneIdentityMarkDescriptor: Equatable, Sendable {
    let cells: [Bool]
    let hue: Double

    init(identityID: String) {
        let digest = Array(SHA256.hash(data: Data(identityID.utf8)))
        var cells = Array(repeating: false, count: 25)
        var bitIndex = 0
        for row in 0..<5 {
            for column in 0..<3 {
                let byte = digest[bitIndex / 8]
                let isFilled = byte & (1 << (bitIndex % 8)) != 0
                cells[(row * 5) + column] = isFilled
                cells[(row * 5) + (4 - column)] = isFilled
                bitIndex += 1
            }
        }
        cells[12] = true
        self.cells = cells
        hue = Double((Int(digest[2]) << 8) | Int(digest[3])) / 65_535
    }
}

nonisolated enum ThaneIdentityCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO 8601 date."
            )
        }
        return decoder
    }
}
