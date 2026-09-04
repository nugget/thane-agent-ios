import Foundation

nonisolated struct ThaneCounterparty: Identifiable, Equatable, Sendable {
    enum Trust: Equatable, Sendable {
        case pinned
        case presented
    }

    let id: String
    let displayName: String
    let shortFingerprint: String
    let trust: Trust

    init(pin: ThaneIdentityPin, presentedEvidence: ThaneIdentityEvidence? = nil) {
        id = pin.identityID
        if let presentedEvidence, pin.matches(presentedEvidence) {
            displayName = presentedEvidence.instance.name
        } else {
            displayName = pin.nameAtPinning
        }
        shortFingerprint = pin.shortFingerprint
        trust = .pinned
    }

    init(evidence: ThaneIdentityEvidence) {
        id = evidence.instance.id
        displayName = evidence.instance.name
        shortFingerprint = evidence.instance.shortFingerprint
        trust = .presented
    }
}
