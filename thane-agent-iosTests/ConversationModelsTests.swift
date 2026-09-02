import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Conversation models")
@MainActor
struct ConversationModelsTests {
    @Test("Conversation identity includes its stable counterparty")
    func counterpartyIsPartOfIdentity() {
        let first = ConversationSummary(
            counterpartyID: "thane:one",
            conversationID: "session-1",
            updatedAt: Date()
        )
        let second = ConversationSummary(
            counterpartyID: "thane:two",
            conversationID: "session-1",
            updatedAt: Date()
        )

        #expect(first.id != second.id)
    }

    @Test("Conversation lists cannot cross counterparty boundaries")
    func filtersAndSortsByCounterparty() {
        let now = Date()
        let store = ConversationStore(summaries: [
            ConversationSummary(
                counterpartyID: "thane:one",
                conversationID: "older",
                updatedAt: now.addingTimeInterval(-60)
            ),
            ConversationSummary(
                counterpartyID: "thane:two",
                conversationID: "other",
                updatedAt: now.addingTimeInterval(60)
            ),
            ConversationSummary(
                counterpartyID: "thane:one",
                conversationID: "newer",
                updatedAt: now
            ),
        ])

        let summaries = store.summaries(forCounterpartyID: "thane:one")

        #expect(summaries.map(\.id.conversationID) == ["newer", "older"])
        #expect(summaries.allSatisfy { $0.id.counterpartyID == "thane:one" })
    }

    @Test("Unread counts are normalized at the domain boundary")
    func unreadCountCannotBeNegative() {
        let summary = ConversationSummary(
            counterpartyID: "thane:one",
            conversationID: "session-1",
            updatedAt: Date(),
            unreadCount: -4
        )

        #expect(summary.unreadCount == 0)
    }
}
