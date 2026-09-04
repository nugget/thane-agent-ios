import Foundation
import Testing
@testable import ThaneIOSCompanion

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

    @Test("Conversation lookup requires both the counterparty and conversation identifier")
    func lookupCannotCrossCounterparties() throws {
        let expected = ConversationSummary(
            counterpartyID: "thane:one",
            conversationID: "shared-session",
            updatedAt: Date()
        )
        let store = ConversationStore(summaries: [
            expected,
            ConversationSummary(
                counterpartyID: "thane:two",
                conversationID: "shared-session",
                updatedAt: Date()
            ),
        ])

        #expect(
            store.summary(
                counterpartyID: "thane:one",
                conversationID: "shared-session"
            ) == expected
        )
        #expect(
            store.summary(
                counterpartyID: "thane:three",
                conversationID: "shared-session"
            ) == nil
        )
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
