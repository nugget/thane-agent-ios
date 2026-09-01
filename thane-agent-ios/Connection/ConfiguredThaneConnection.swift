import Foundation

nonisolated struct ConfiguredThaneConnection: Identifiable, Equatable, Sendable {
    let id: String
    let endpoint: URL?
    let counterparty: ThaneCounterparty?
}
