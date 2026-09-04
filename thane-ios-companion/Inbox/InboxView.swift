import SwiftUI

struct InboxView: View {
    let profile: AgentProfile
    let counterparty: ThaneCounterparty

    @State private var operationError: String?

    var body: some View {
        Group {
            if let error = profile.inboxStore.lastError ?? operationError {
                ContentUnavailableView {
                    Label("Inbox Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            } else if profile.inboxStore.records.isEmpty {
                ContentUnavailableView {
                    Label("Inbox Empty", systemImage: "tray")
                } description: {
                    Text("Updates and suggestions from \(counterparty.displayName) will appear here.")
                }
            } else {
                List(profile.inboxStore.records) { record in
                    NavigationLink(
                        value: AppDestination.inboxItem(
                            counterpartyID: counterparty.id,
                            itemID: record.id
                        )
                    ) {
                        InboxRow(record: record)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if profile.inboxStore.unreadCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark All Read") {
                        do {
                            try profile.inboxStore.markAllRead()
                            operationError = nil
                        } catch {
                            operationError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

struct InboxItemView: View {
    let profile: AgentProfile
    let counterparty: ThaneCounterparty
    let record: InboxRecord

    @State private var operationError: String?

    var body: some View {
        List {
            Section {
                Label(record.kind.label, systemImage: record.kind.systemImage)
                    .foregroundStyle(.secondary)

                Text(record.title)
                    .font(.title3.weight(.semibold))

                if !record.summary.isEmpty {
                    Text(record.summary)
                        .textSelection(.enabled)
                }

                LabeledContent("Received") {
                    Text(record.createdAt, format: .dateTime)
                }
            }

            if let conversationID = record.relatedConversationID,
               profile.conversationStore.summary(
                   counterpartyID: counterparty.id,
                   conversationID: conversationID
               ) != nil {
                Section {
                    NavigationLink(
                        "Open Conversation",
                        value: AppDestination.conversation(
                            counterpartyID: counterparty.id,
                            conversationID: conversationID
                        )
                    )
                }
            }

            if let operationError {
                Section {
                    Label(operationError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(counterparty.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            do {
                try profile.inboxStore.markRead(id: record.id)
                operationError = nil
            } catch {
                operationError = error.localizedDescription
            }
        }
    }
}

struct InboxIdentityUnavailableView: View {
    let counterparty: ThaneCounterparty

    var body: some View {
        ContentUnavailableView {
            Label("Inbox Unavailable", systemImage: "exclamationmark.shield")
        } description: {
            Text("Pin \(counterparty.displayName)'s identity before viewing its private inbox history.")
        }
        .navigationTitle("Inbox")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct InboxRow: View {
    let record: InboxRecord

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: record.kind.systemImage)
                .font(.title3)
                .frame(width: 28)
                .foregroundStyle(record.isRead ? Color.secondary : Color.blue)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(record.title)
                        .font(.headline)
                    Spacer()
                    Text(record.createdAt, format: .relative(presentation: .named))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !record.summary.isEmpty {
                    Text(record.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if !record.isRead {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
        .padding(.vertical, 4)
    }
}

private extension InboxKind {
    var label: String {
        switch self {
        case .information: "Update"
        case .suggestion: "Suggestion"
        case .actionRequired: "Action Required"
        case .conversation: "Conversation"
        }
    }

    var systemImage: String {
        switch self {
        case .information: "info.circle"
        case .suggestion: "sparkles"
        case .actionRequired: "checklist"
        case .conversation: "bubble.left.and.bubble.right"
        }
    }
}

#if DEBUG
#Preview("Inbox") {
    let appState = PreviewFixtures.appState()
    NavigationStack {
        if let counterparty = appState.activeProfile.counterparty {
            InboxView(profile: appState.activeProfile, counterparty: counterparty)
        }
    }
}
#endif
