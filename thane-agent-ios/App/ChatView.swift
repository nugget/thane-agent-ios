import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var appState

    let openSettings: () -> Void

    var body: some View {
        Group {
            if let counterparty = appState.counterparty {
                let conversations = appState.conversationStore.summaries(
                    forCounterpartyID: counterparty.id
                )
                if conversations.isEmpty {
                    ContentUnavailableView {
                        Label("No Conversations", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Chat sessions with \(counterparty.displayName) will appear here.")
                    } actions: {
                        NavigationLink("View \(counterparty.displayName)") {
                            CounterpartyDetailView(counterparty: counterparty)
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    List(conversations) { conversation in
                        NavigationLink {
                            ConversationView(
                                conversation: conversation,
                                counterparty: counterparty
                            )
                        } label: {
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
            if let counterparty = appState.counterparty {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        CounterpartyDetailView(counterparty: counterparty)
                    } label: {
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

private struct ConversationView: View {
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
                NavigationLink {
                    CounterpartyDetailView(counterparty: counterparty)
                } label: {
                    ThaneIdentityMark(identityID: counterparty.id, size: 30)
                }
                .accessibilityLabel("View \(counterparty.displayName)")
            }
        }
    }
}

#Preview("Conversations") {
    let evidence = try! ThaneIdentityCoding.decoder().decode(
        ThaneIdentityEvidence.self,
        from: Data(
            #"{"schema_version":1,"observed_at":"2026-08-30T19:22:31Z","instance":{"id":"thane:preview:aimee","name":"Aimée","identity_key":{"algorithm":"ed25519","fingerprint":"SHA256:previewidentity"},"channel_ca":{"algorithm":"x509-ed25519","fingerprint":"SHA256:previewca"}},"core":{"birth":{"commit":{"algorithm":"sha1","oid":"0123456789abcdef"},"asserted_at":"2026-07-01T12:00:00Z","time_assurance":"signed_claim","anchor":"operator"},"current_commit":{"algorithm":"sha1","oid":"fedcba9876543210"},"head":{"worktree_clean":true,"trust_file_change_count":0},"verification":{"admission":{"status":"verified","detail":"verified"},"head":{"status":"verified","detail":"verified"}}}}"#.utf8
        )
    )
    let connectionSettings = ConnectionSettings(
        defaults: UserDefaults(suiteName: "ChatViewPreview") ?? .standard,
        credentialStore: PreviewCredentialStore()
    )
    let appState = AppState(
        connectionSettings: connectionSettings,
        sharingPreferences: SharingPreferences(
            defaults: UserDefaults(suiteName: "ChatViewPreview") ?? .standard
        ),
        identityPinning: {
            let pinning = IdentityPinningService(
                connectionID: connectionSettings.connectionID,
                secureStore: PreviewCredentialStore()
            )
            try! pinning.pin(evidence)
            return pinning
        }(),
        conversationStore: ConversationStore(summaries: [
            ConversationSummary(
                counterpartyID: evidence.instance.id,
                conversationID: "planning",
                title: "Weekend planning",
                latestMessagePreview: "I found two openings that fit your calendar.",
                updatedAt: Date(),
                unreadCount: 2
            ),
        ])
    )
    NavigationStack {
        ChatView {}
    }
    .environment(appState)
}

@MainActor
private final class PreviewCredentialStore: CredentialStoring {
    private var values: [String: String] = [:]

    func save(_ value: String, account: String) {
        values[account] = value
    }

    func load(account: String) -> String? {
        values[account]
    }

    func delete(account: String) {
        values[account] = nil
    }
}
