import Foundation

nonisolated struct ConversationKey: Hashable, Sendable {
    let counterpartyID: String
    let conversationID: String
}

nonisolated struct ConversationSummary: Identifiable, Equatable, Sendable {
    let id: ConversationKey
    let title: String?
    let latestMessagePreview: String?
    let updatedAt: Date
    let unreadCount: Int

    init(
        counterpartyID: String,
        conversationID: String,
        title: String? = nil,
        latestMessagePreview: String? = nil,
        updatedAt: Date,
        unreadCount: Int = 0
    ) {
        id = ConversationKey(
            counterpartyID: counterpartyID,
            conversationID: conversationID
        )
        self.title = title
        self.latestMessagePreview = latestMessagePreview
        self.updatedAt = updatedAt
        self.unreadCount = max(0, unreadCount)
    }
}

@Observable
@MainActor
final class ConversationStore {
    private(set) var summaries: [ConversationSummary]

    init(summaries: [ConversationSummary] = []) {
        self.summaries = summaries
    }

    func summaries(forCounterpartyID counterpartyID: String) -> [ConversationSummary] {
        summaries
            .filter { $0.id.counterpartyID == counterpartyID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func replace(with summaries: [ConversationSummary]) {
        self.summaries = summaries
    }
}
