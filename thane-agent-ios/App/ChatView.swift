import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState

    let openSettings: () -> Void

    var body: some View {
        let profile = appState.activeProfile
        Group {
            if let counterparty = profile.counterparty {
                let conversations = profile.conversationStore.summaries(
                    forCounterpartyID: counterparty.id
                )
                if conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Chat sessions with \(counterparty.displayName) will appear here.")
                    } actions: {
                        NavigationLink(
                            "View \(counterparty.displayName)",
                            value: AppDestination.counterparty(counterpartyID: counterparty.id)
                        )
                        .buttonStyle(.bordered)
                    }
                } else {
                    List(conversations) { conversation in
                        NavigationLink(
                            value: AppDestination.conversation(
                                counterpartyID: counterparty.id,
                                conversationID: conversation.id.conversationID
                            )
                        ) {
                            ConversationRow(
                                conversation: conversation,
                                counterparty: counterparty
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            } else {
                ContentUnavailableView {
                    Label("No Agent Connected", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Add an agent connection to start conversations and choose what this iPhone shares.")
                } actions: {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Chats")
        .toolbar {
            if let counterparty = profile.counterparty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(
                        value: AppDestination.counterparty(counterpartyID: counterparty.id)
                    ) {
                        ThaneIdentityMark(identityID: counterparty.id, size: 30)
                    }
                    .accessibilityLabel("View \(counterparty.displayName)")
                }
            }
        }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary
    let counterparty: ThaneCounterparty

    var body: some View {
        HStack(spacing: 12) {
            ThaneIdentityMark(identityID: counterparty.id, size: 48)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(conversation.title ?? counterparty.displayName)
                        .font(.headline)
                    Spacer()
                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(conversation.latestMessagePreview ?? "No messages yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount.formatted())
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.blue, in: Capsule())
                            .accessibilityLabel("\(conversation.unreadCount) unread")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct ConversationView: View {
    let profile: AgentProfile
    let conversation: ConversationSummary
    let counterparty: ThaneCounterparty

    var body: some View {
        ContentUnavailableView {
            Label("No Messages Yet", systemImage: "bubble.left")
        } description: {
            Text("This conversation belongs to \(counterparty.displayName).")
        }
        .navigationTitle(conversation.title ?? counterparty.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(
                    value: AppDestination.counterparty(counterpartyID: counterparty.id)
                ) {
                    ThaneIdentityMark(identityID: counterparty.id, size: 30)
                }
                .accessibilityLabel("View \(counterparty.displayName)")
            }
        }
    }
}

struct AppDestinationView: View {
    let profile: AgentProfile
    let destination: AppDestination
    let openSettings: () -> Void

    var body: some View {
        if let counterparty = profile.counterparty,
           counterparty.id == destination.counterpartyID {
            destinationView(counterparty: counterparty)
        } else {
            ContentUnavailableView {
                Label("Destination Unavailable", systemImage: "exclamationmark.shield")
            } description: {
                Text("This destination does not belong to the active Thane identity.")
            }
        }
    }

    @ViewBuilder
    private func destinationView(counterparty: ThaneCounterparty) -> some View {
        switch destination {
        case .conversations:
            ChatView(openSettings: openSettings)
        case .counterparty:
            CounterpartyDetailView(
                profile: profile,
                counterparty: counterparty
            )
        case .conversation(_, let conversationID):
            if let conversation = profile.conversationStore.summary(
                counterpartyID: counterparty.id,
                conversationID: conversationID
            ) {
                ConversationView(
                    profile: profile,
                    conversation: conversation,
                    counterparty: counterparty
                )
            } else {
                ContentUnavailableView {
                    Label("Conversation Unavailable", systemImage: "exclamationmark.bubble")
                } description: {
                    Text("This conversation is not available for \(counterparty.displayName) on this iPhone.")
                }
                .navigationTitle(counterparty.displayName)
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

#if DEBUG
#Preview("Conversations") {
    NavigationStack {
        ChatView {}
    }
    .environment(PreviewFixtures.appState())
}
#endif
