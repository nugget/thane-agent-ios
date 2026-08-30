import Foundation

nonisolated struct ThaneIdentityPin: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let identityID: String
    let nameAtPinning: String
    let identityKey: PublicIdentityMaterial
    let channelCA: PublicIdentityMaterial
    let pinnedAt: Date

    init(evidence: ThaneIdentityEvidence, pinnedAt: Date = Date()) {
        schemaVersion = Self.currentSchemaVersion
        identityID = evidence.instance.id
        nameAtPinning = evidence.instance.name
        identityKey = evidence.instance.identityKey
        channelCA = evidence.instance.channelCA
        self.pinnedAt = pinnedAt
    }

    func matches(_ evidence: ThaneIdentityEvidence) -> Bool {
        identityID == evidence.instance.id
            && identityKey == evidence.instance.identityKey
            && channelCA == evidence.instance.channelCA
    }

    var shortFingerprint: String {
        ThaneInstanceIdentity.shortened(identityKey.fingerprint)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case identityID = "identity_id"
        case nameAtPinning = "name_at_pinning"
        case identityKey = "identity_key"
        case channelCA = "channel_ca"
        case pinnedAt = "pinned_at"
    }
}

nonisolated enum IdentityContinuityState: Equatable, Sendable {
    static let maximumEvidenceAge: TimeInterval = 15 * 60

    case notPinned
    case presented
    case matching
    case stale
    case unavailable
    case mismatch

    static func evaluate(
        pin: ThaneIdentityPin?,
        evidence: ThaneIdentityEvidence?,
        now: Date = Date()
    ) -> IdentityContinuityState {
        guard let pin else {
            return evidence == nil ? .notPinned : .presented
        }
        guard let evidence else { return .unavailable }
        guard pin.matches(evidence) else { return .mismatch }
        return now.timeIntervalSince(evidence.observedAt) > maximumEvidenceAge
            ? .stale
            : .matching
    }

    var permitsPrivateDelivery: Bool {
        self == .matching || self == .stale
    }
}

nonisolated enum IdentityPinError: LocalizedError, Equatable {
    case corruptPin
    case unsupportedSchema(Int)
    case alreadyPinned
    case storageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .corruptPin:
            "The saved Thane identity pin is unreadable. Forget it before establishing a new pin."
        case .unsupportedSchema(let version):
            "The saved Thane identity pin uses unsupported schema version \(version)."
        case .alreadyPinned:
            "Forget the current Thane identity before pinning a different identity."
        case .storageUnavailable(let message):
            "The Thane identity pin is unavailable: \(message)"
        }
    }
}

@Observable
@MainActor
final class IdentityPinningService {
    private nonisolated static let pinAccount = "thane-identity-pin"

    private(set) var pin: ThaneIdentityPin?
    private(set) var lastError: String?

    private let secureStore: any CredentialStoring
    private var blockingError: IdentityPinError?

    init(secureStore: any CredentialStoring = KeychainCredentialStore()) {
        self.secureStore = secureStore
        do {
            pin = try Self.loadPin(from: secureStore)
        } catch let error as IdentityPinError {
            pin = nil
            blockingError = error
            lastError = error.localizedDescription
        } catch {
            let pinError = IdentityPinError.storageUnavailable(error.localizedDescription)
            pin = nil
            blockingError = pinError
            lastError = pinError.localizedDescription
        }
    }

    func pin(_ evidence: ThaneIdentityEvidence, at date: Date = Date()) throws {
        guard pin == nil else { throw IdentityPinError.alreadyPinned }
        if let blockingError { throw blockingError }
        let newPin = ThaneIdentityPin(evidence: evidence, pinnedAt: date)
        let data = try JSONEncoder().encode(newPin)
        guard let value = String(data: data, encoding: .utf8) else {
            throw IdentityPinError.corruptPin
        }
        try secureStore.save(value, account: Self.pinAccount)
        pin = newPin
        blockingError = nil
        lastError = nil
    }

    func forget() throws {
        try secureStore.delete(account: Self.pinAccount)
        pin = nil
        blockingError = nil
        lastError = nil
    }

    private static func loadPin(from store: any CredentialStoring) throws -> ThaneIdentityPin? {
        guard let value = try store.load(account: pinAccount),
              let data = value.data(using: .utf8) else {
            return nil
        }
        let pin: ThaneIdentityPin
        do {
            pin = try JSONDecoder().decode(ThaneIdentityPin.self, from: data)
        } catch {
            throw IdentityPinError.corruptPin
        }
        guard pin.schemaVersion == ThaneIdentityPin.currentSchemaVersion else {
            throw IdentityPinError.unsupportedSchema(pin.schemaVersion)
        }
        return pin
    }
}
