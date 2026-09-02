import Foundation

nonisolated enum InboxKind: String, CaseIterable, Codable, Sendable {
    case information
    case suggestion
    case actionRequired = "action_required"
    case conversation
}

nonisolated struct InboxRecord: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let counterpartyID: String
    let kind: InboxKind
    let title: String
    let summary: String
    let createdAt: Date
    var isRead: Bool
    let relatedConversationID: String?

    init(
        id: String,
        counterpartyID: String,
        kind: InboxKind,
        title: String,
        summary: String,
        createdAt: Date,
        isRead: Bool = false,
        relatedConversationID: String? = nil
    ) {
        self.id = id
        self.counterpartyID = counterpartyID
        self.kind = kind
        self.title = title
        self.summary = summary
        self.createdAt = createdAt
        self.isRead = isRead
        self.relatedConversationID = relatedConversationID
    }
}
