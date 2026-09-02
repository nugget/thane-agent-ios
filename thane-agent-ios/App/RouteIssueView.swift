import SwiftUI

struct RouteIssueView: View {
    @Environment(\.dismiss) private var dismiss

    let issue: AppRouteIssue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(title, systemImage: "exclamationmark.shield")
                        .font(.headline)
                    Text(message)
                        .foregroundStyle(.secondary)
                }

                if let requestedCounterpartyID = issue.requestedCounterpartyID {
                    identitySection(
                        title: "Requested Thane",
                        name: nil,
                        identityID: requestedCounterpartyID
                    )
                }

                if let activeIdentity = issue.activeIdentity {
                    identitySection(
                        title: "Active Thane",
                        name: activeIdentity.displayName,
                        identityID: activeIdentity.id
                    )
                } else if issue.reason == .identityMismatch {
                    Section("Active Thane") {
                        Text("No Thane identity is currently active.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Link Not Opened")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var title: String {
        switch issue.reason {
        case .invalidLink:
            "Invalid Thane Link"
        case .identityMismatch:
            "Different Thane Identity"
        }
    }

    private var message: String {
        switch issue.reason {
        case .invalidLink(let error):
            error.localizedDescription
        case .identityMismatch:
            "The link targets a different Thane identity. Nothing was opened or switched automatically."
        }
    }

    private func identitySection(
        title: String,
        name: String?,
        identityID: String
    ) -> some View {
        Section(title) {
            if let name {
                Text(name)
                    .font(.headline)
            }
            Text(identityID)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}

#if DEBUG
#Preview("Identity Mismatch") {
    RouteIssueView(
        issue: AppRouteIssue(
            reason: .identityMismatch,
            requestedCounterpartyID: "thane:ed25519:SHA256:another-agent",
            activeIdentity: AppRouteIdentity(PreviewFixtures.counterparty)
        )
    )
}
#endif
