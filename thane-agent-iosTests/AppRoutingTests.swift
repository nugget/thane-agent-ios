import Foundation
import Testing

@testable import thane_agent_ios

@Suite("Identity-bound app routing")
struct AppRoutingTests {
    @Test("Versioned read-only routes parse into protocol-neutral destinations")
    func parsesReadOnlyDestinations() throws {
        let cases: [(String, AppDestination)] = [
            (
                "thane://v1/agents/thane%3Aed25519%3ASHA256%3Apocket",
                .counterparty(counterpartyID: "thane:ed25519:SHA256:pocket")
            ),
            (
                "thane://v1/agents/thane%3Aed25519%3ASHA256%3Apocket/conversations",
                .conversations(counterpartyID: "thane:ed25519:SHA256:pocket")
            ),
            (
                "thane://v1/agents/thane%3Aed25519%3ASHA256%3Apocket/conversations/session-1",
                .conversation(
                    counterpartyID: "thane:ed25519:SHA256:pocket",
                    conversationID: "session-1"
                )
            ),
        ]

        for (rawURL, expected) in cases {
            let url = try #require(URL(string: rawURL))
            #expect(try ThaneURLParser.parse(url) == expected)
        }
    }

    @Test("Generated routes round-trip reserved identity characters")
    func generatedRoutesRoundTrip() throws {
        let destination = AppDestination.conversation(
            counterpartyID: "thane:ed25519:SHA256:a/b+c==",
            conversationID: "session_1~draft"
        )

        let url = try #require(destination.externalURL)

        #expect(url.absoluteString.contains("a%2Fb%2Bc%3D%3D"))
        #expect(try ThaneURLParser.parse(url) == destination)
    }

    @Test("Untrusted URLs cannot carry credentials or private payload data")
    func rejectsUnsafeInput() throws {
        let oversizedID = String(repeating: "a", count: 2_100)
        let unsafeURLs = [
            "https://v1/agents/thane%3Aone",
            "thane://v2/agents/thane%3Aone",
            "thane://token@v1/agents/thane%3Aone",
            "thane://v1:443/agents/thane%3Aone",
            "thane://v1/agents/thane%3Aone?token=secret",
            "thane://v1/agents/thane%3Aone#message=hello",
            "thane://v1/location/41.8,-87.6",
            "thane://v1/agents/thane%3Aone/messages/hello",
            "thane://v1/agents/thane%3Aone/conversations/session%2Fprivate",
            "thane://v1/agents/\(oversizedID)",
        ]

        for rawURL in unsafeURLs {
            let url = try #require(URL(string: rawURL))
            #expect(throws: ThaneURLParseError.self) {
                _ = try ThaneURLParser.parse(url)
            }
        }
    }

    @Test("Identifier bounds and route shapes fail explicitly")
    func rejectsInvalidIdentifiers() throws {
        let invalidCases: [(String, ThaneURLParseError)] = [
            ("thane://v1/agents/", .unknownDestination),
            ("thane://v1/agents/%2E%2E", .invalidCounterpartyID),
            (
                "thane://v1/agents/thane%3Aone/conversations/has%20spaces",
                .invalidConversationID
            ),
        ]

        for (rawURL, expectedError) in invalidCases {
            let url = try #require(URL(string: rawURL))
            #expect(throws: expectedError) {
                _ = try ThaneURLParser.parse(url)
            }
        }
    }
}

@Suite("App router")
@MainActor
struct AppRouterTests {
    @Test("A matching identity opens the requested conversation")
    func matchingIdentityRoutes() throws {
        let counterparty = ThaneCounterparty(evidence: try IdentityTestFixture.evidence())
        let destination = AppDestination.conversation(
            counterpartyID: counterparty.id,
            conversationID: "session-1"
        )
        let router = AppRouter(selectedSection: .settings)

        router.navigate(to: destination, activeCounterparty: counterparty)

        #expect(router.selectedSection == .chats)
        #expect(router.chatPath == [destination])
        #expect(router.issue == nil)
    }

    @Test("A conversation-list route returns to the identity-bound chat root")
    func conversationListRoutesToRoot() throws {
        let counterparty = ThaneCounterparty(evidence: try IdentityTestFixture.evidence())
        let router = AppRouter(
            chatPath: [
                .counterparty(counterpartyID: counterparty.id),
            ]
        )

        router.navigate(
            to: .conversations(counterpartyID: counterparty.id),
            activeCounterparty: counterparty
        )

        #expect(router.selectedSection == .chats)
        #expect(router.chatPath.isEmpty)
    }

    @Test("An identity mismatch preserves navigation and exposes comparison evidence")
    func identityMismatchFailsClosed() throws {
        let counterparty = ThaneCounterparty(evidence: try IdentityTestFixture.evidence())
        let existing = AppDestination.counterparty(counterpartyID: counterparty.id)
        let router = AppRouter(selectedSection: .settings, chatPath: [existing])

        router.navigate(
            to: .conversation(
                counterpartyID: "thane:ed25519:SHA256:different",
                conversationID: "session-1"
            ),
            activeCounterparty: counterparty
        )

        #expect(router.selectedSection == .settings)
        #expect(router.chatPath == [existing])
        #expect(router.issue?.reason == .identityMismatch)
        #expect(
            router.issue?.requestedCounterpartyID
                == "thane:ed25519:SHA256:different"
        )
        #expect(router.issue?.activeIdentity == AppRouteIdentity(counterparty))
    }

    @Test("No active identity cannot open an identity-bound destination")
    func absentIdentityFailsClosed() {
        let router = AppRouter()

        router.navigate(
            to: .counterparty(counterpartyID: "thane:ed25519:SHA256:pocket"),
            activeCounterparty: nil
        )

        #expect(router.chatPath.isEmpty)
        #expect(router.issue?.reason == .identityMismatch)
        #expect(router.issue?.activeIdentity == nil)
    }

    @Test("Restored navigation is cleared when the active identity changes")
    func restorationCannotCrossIdentities() {
        let destination = AppDestination.conversation(
            counterpartyID: "thane:ed25519:SHA256:first",
            conversationID: "session-1"
        )
        let router = AppRouter(chatPath: [destination])

        router.reconcile(activeCounterpartyID: "thane:ed25519:SHA256:first")

        #expect(router.chatPath == [destination])

        router.reconcile(activeCounterpartyID: "thane:ed25519:SHA256:second")

        #expect(router.chatPath.isEmpty)
    }

    @Test("Invalid external input does not change navigation")
    func invalidURLFailsClosed() throws {
        let counterparty = ThaneCounterparty(evidence: try IdentityTestFixture.evidence())
        let existing = AppDestination.counterparty(counterpartyID: counterparty.id)
        let router = AppRouter(chatPath: [existing])
        let url = try #require(URL(string: "thane://v1/agents/thane%3Aone?token=secret"))

        router.open(url, activeCounterparty: counterparty)

        #expect(router.chatPath == [existing])
        #expect(router.issue?.reason == .invalidLink(.embeddedData))
    }
}
