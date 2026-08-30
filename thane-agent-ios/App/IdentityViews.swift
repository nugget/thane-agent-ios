import SwiftUI

struct ThaneIdentityMark: View {
    let identityID: String
    var size: CGFloat = 52

    private var descriptor: ThaneIdentityMarkDescriptor {
        ThaneIdentityMarkDescriptor(identityID: identityID)
    }

    var body: some View {
        Canvas { context, canvasSize in
            let cellSize = canvasSize.width / 7
            let gap = cellSize * 0.18
            for index in descriptor.cells.indices where descriptor.cells[index] {
                let row = index / 5
                let column = index % 5
                let rect = CGRect(
                    x: cellSize + CGFloat(column) * cellSize + gap,
                    y: cellSize + CGFloat(row) * cellSize + gap,
                    width: cellSize - (gap * 2),
                    height: cellSize - (gap * 2)
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: cellSize * 0.18),
                    with: .color(Color(hue: descriptor.hue, saturation: 0.68, brightness: 0.82))
                )
            }
        }
        .frame(width: size, height: size)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct IdentitySummaryButton: View {
    let evidence: ThaneIdentityEvidence
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ThaneIdentityMark(identityID: evidence.instance.id)

                VStack(alignment: .leading, spacing: 3) {
                    Text(evidence.instance.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(evidence.instance.shortFingerprint)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("Presented identity")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Presented Thane identity \(evidence.instance.name), fingerprint \(evidence.instance.shortFingerprint)"
        )
        .accessibilityHint("Shows cryptographic identity and core evidence")
    }
}

struct IdentityEvidenceView: View {
    let evidence: ThaneIdentityEvidence
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        ThaneIdentityMark(identityID: evidence.instance.id, size: 84)
                        Text(evidence.instance.name)
                            .font(.title2.weight(.semibold))
                        Text(evidence.instance.shortFingerprint)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)

                    Text("This identity was presented by the configured endpoint. It has not yet been pinned or independently verified by this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Stable identity") {
                    EvidenceValueRow(label: "Instance ID", value: evidence.instance.id)
                    EvidenceValueRow(
                        label: "Signing key · \(evidence.instance.identityKey.algorithm)",
                        value: evidence.instance.identityKey.fingerprint
                    )
                    EvidenceValueRow(
                        label: "Channel CA · \(evidence.instance.channelCA.algorithm)",
                        value: evidence.instance.channelCA.fingerprint
                    )

                    Text("The visual mark is derived from the stable instance ID as a recognition aid; it is not proof by itself.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Core origin") {
                    LabeledContent("Anchor posture", value: anchorLabel)
                    EvidenceValueRow(
                        label: "Birth commit · \(evidence.core.birth.commit.algorithm)",
                        value: evidence.core.birth.commit.oid
                    )
                    LabeledContent(
                        "Asserted birth time",
                        value: evidence.core.birth.assertedAt.formatted(date: .abbreviated, time: .standard)
                    )

                    Text("The birth time is a claim covered by the signed birth commit. It is not an independently witnessed timestamp.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Current core") {
                    EvidenceValueRow(
                        label: "Current commit · \(evidence.core.currentCommit.algorithm)",
                        value: evidence.core.currentCommit.oid
                    )
                    LabeledContent(
                        "Tracked worktree",
                        value: evidence.core.head.worktreeClean ? "Clean" : "Modified"
                    )
                    LabeledContent(
                        "Trust-file revisions",
                        value: evidence.core.head.trustFileChangeCount.formatted()
                    )
                }

                Section("Local verification") {
                    VerificationRow(title: "Birth admission", check: evidence.core.verification.admission)
                    VerificationRow(title: "Current HEAD", check: evidence.core.verification.head)

                    Text("These are checks reported from the running Thane's core. They are evidence for the operator to evaluate, not a universal trust verdict.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent(
                        "Observed",
                        value: evidence.observedAt.formatted(date: .abbreviated, time: .standard)
                    )
                    LabeledContent("Schema", value: evidence.schemaVersion.formatted())
                }
            }
            .navigationTitle("Thane Identity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var anchorLabel: String {
        switch evidence.core.birth.anchor {
        case "operator": "Operator-anchored declaration"
        case "self_signed": "Self-signed declaration"
        default: "Unknown declaration"
        }
    }
}

private struct EvidenceValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.subheadline)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

private struct VerificationRow: View {
    let title: String
    let check: IdentityCheckEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                check.isVerified ? "\(title): locally verified" : "\(title): \(check.status)",
                systemImage: check.isVerified ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(check.isVerified ? .green : .orange)
            Text(check.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
