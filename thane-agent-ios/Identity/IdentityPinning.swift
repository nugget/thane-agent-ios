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
            && identityKey.hasSameIdentity(as: evidence.instance.identityKey)
            && channelCA.hasSameIdentity(as: evidence.instance.channelCA)
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

private extension PublicIdentityMaterial {
    nonisolated func hasSameIdentity(as other: PublicIdentityMaterial) -> Bool {
        algorithm == other.algorithm && fingerprint == other.fingerprint
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
    private(set) var pin: ThaneIdentityPin?
    private(set) var lastError: String?
    private(set) var connectionID: String

    private let secureStore: any CredentialStoring
    private var blockingError: IdentityPinError?

    init(
        connectionID: String,
        secureStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.connectionID = connectionID
        self.secureStore = secureStore
        do {
            pin = try Self.loadPin(
                from: secureStore,
                scope: ConnectionSecurityScope(connectionID: connectionID)
            )
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
        try secureStore.save(value, account: securityScope.identityPinAccount)
        try secureStore.delete(account: ConnectionSecurityScope.legacyIdentityPinAccount)
        pin = newPin
        blockingError = nil
        lastError = nil
    }

    func forget() throws {
        try secureStore.delete(account: securityScope.identityPinAccount)
        try secureStore.delete(account: ConnectionSecurityScope.legacyIdentityPinAccount)
        pin = nil
        blockingError = nil
        lastError = nil
    }

    func changeScope(to connectionID: String) throws {
        guard self.connectionID != connectionID else { return }
        let newScope = ConnectionSecurityScope(connectionID: connectionID)
        let loadedPin = try Self.loadPin(from: secureStore, scope: newScope)
        self.connectionID = connectionID
        pin = loadedPin
        blockingError = nil
        lastError = nil
    }

    private var securityScope: ConnectionSecurityScope {
        ConnectionSecurityScope(connectionID: connectionID)
    }

    private static func loadPin(
        from store: any CredentialStoring,
        scope: ConnectionSecurityScope
    ) throws -> ThaneIdentityPin? {
        if let scopedValue = try store.load(account: scope.identityPinAccount) {
            try store.delete(account: ConnectionSecurityScope.legacyIdentityPinAccount)
            return try decodePin(scopedValue)
        }
        guard let legacyValue = try store.load(
            account: ConnectionSecurityScope.legacyIdentityPinAccount
        ) else {
            return nil
        }
        let pin = try decodePin(legacyValue)
        try store.save(legacyValue, account: scope.identityPinAccount)
        try store.delete(account: ConnectionSecurityScope.legacyIdentityPinAccount)
        return pin
    }

    private static func decodePin(_ value: String) throws -> ThaneIdentityPin {
        guard let data = value.data(using: .utf8) else {
            throw IdentityPinError.corruptPin
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
