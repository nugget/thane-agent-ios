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

struct IdentitySummary: View {
    let evidence: ThaneIdentityEvidence
    var status: String = "Presented identity"

    var body: some View {
        HStack(spacing: 14) {
            ThaneIdentityMark(identityID: evidence.instance.id)

            VStack(alignment: .leading, spacing: 3) {
                Text(evidence.instance.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(evidence.instance.shortFingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityLabel(
            "Agent identity \(evidence.instance.name), fingerprint \(evidence.instance.shortFingerprint), \(status)"
        )
    }
}

struct PinnedIdentitySummary: View {
    let pin: ThaneIdentityPin
    let status: String

    var body: some View {
        HStack(spacing: 14) {
            ThaneIdentityMark(identityID: pin.identityID)

            VStack(alignment: .leading, spacing: 3) {
                Text(pin.nameAtPinning)
                    .font(.title3.weight(.semibold))
                Text(pin.shortFingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Pinned agent identity \(pin.nameAtPinning), fingerprint \(pin.shortFingerprint), \(status)"
        )
    }
}

struct IdentityPinView: View {
    let pin: ThaneIdentityPin

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    ThaneIdentityMark(identityID: pin.identityID, size: 84)
                    Text(pin.nameAtPinning)
                        .font(.title2.weight(.semibold))
                    Text(pin.shortFingerprint)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)

                Text("This is the identity material recorded in this iPhone's protected Keychain. Matching does not independently prove who operates this agent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Pinned stable identity") {
                EvidenceValueRow(label: "Instance ID", value: pin.identityID)
                EvidenceValueRow(
                    label: "Signing key · \(pin.identityKey.algorithm)",
                    value: pin.identityKey.fingerprint
                )
                EvidenceValueRow(
                    label: "Channel CA · \(pin.channelCA.algorithm)",
                    value: pin.channelCA.fingerprint
                )
            }

            Section {
                LabeledContent(
                    "Pinned on this iPhone",
                    value: pin.pinnedAt.formatted(date: .abbreviated, time: .standard)
                )
                LabeledContent("Pin schema", value: pin.schemaVersion.formatted())
            }
        }
        .navigationTitle("Pinned Identity")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct IdentityEvidenceView: View {
    let evidence: ThaneIdentityEvidence
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
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

                Text(continuityExplanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Continuity on this iPhone") {
                Label(continuityTitle, systemImage: continuitySymbol)
                    .foregroundStyle(continuityColor)

                if appState.identityContinuity == .presented {
                    Button("Pin \(evidence.instance.name) & Connect") {
                        appState.pinPresentedIdentity()
                        if appState.identityContinuity.permitsPrivateDelivery {
                            dismiss()
                        }
                    }
                } else if let pin = appState.identityPinning.pin {
                    LabeledContent(
                        "Pinned on this iPhone",
                        value: pin.pinnedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    if appState.identityContinuity == .mismatch {
                        EvidenceValueRow(label: "Pinned instance ID", value: pin.identityID)
                        EvidenceValueRow(
                            label: "Pinned signing key · \(pin.identityKey.algorithm)",
                            value: pin.identityKey.fingerprint
                        )
                        EvidenceValueRow(
                            label: "Pinned channel CA · \(pin.channelCA.algorithm)",
                            value: pin.channelCA.fingerprint
                        )
                    }
                }

                Text("A pin records the stable instance ID, signing-key fingerprint, and channel-CA fingerprint in this iPhone's protected Keychain. It does not independently prove who operates this agent.")
                    .font(.caption)
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

            Section("Reported core verification") {
                VerificationRow(title: "Birth admission", check: evidence.core.verification.admission)
                VerificationRow(title: "Current HEAD", check: evidence.core.verification.head)

                Text("These are checks reported from the running agent's core. They are evidence for the operator to evaluate, not a universal trust verdict.")
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
        .navigationTitle("Identity Evidence")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var anchorLabel: String {
        switch evidence.core.birth.anchor {
        case "operator": "Operator-anchored declaration"
        case "self_signed": "Self-signed declaration"
        default: "Unknown declaration"
        }
    }

    private var continuityTitle: String {
        switch appState.identityContinuity {
        case .notPinned, .presented: "Presented, not pinned"
        case .matching: "Pinned identity matches"
        case .stale: "Pinned identity matches; evidence is stale"
        case .unavailable: "Current evidence unavailable"
        case .mismatch: "Identity mismatch; private delivery blocked"
        }
    }

    private var continuityExplanation: String {
        switch appState.identityContinuity {
        case .notPinned, .presented:
            "This identity was presented by the configured endpoint. Review the exact evidence before choosing to pin it on this iPhone."
        case .matching:
            "The stable instance ID, signing key, and channel CA exactly match this iPhone's pin."
        case .stale:
            "The stable identity matches this iPhone's pin, but the evidence snapshot is older than 15 minutes."
        case .unavailable:
            "This iPhone has a pin, but current identity evidence is unavailable. Private delivery remains disabled until evidence can be compared."
        case .mismatch:
            "The configured endpoint presented different stable identity material. Live requests and observation uploads are blocked."
        }
    }

    private var continuitySymbol: String {
        switch appState.identityContinuity {
        case .matching: "checkmark.shield.fill"
        case .stale: "clock.badge.exclamationmark"
        case .mismatch: "exclamationmark.shield.fill"
        case .unavailable: "questionmark.diamond"
        case .notPinned, .presented: "pin.circle"
        }
    }

    private var continuityColor: Color {
        switch appState.identityContinuity {
        case .matching: .green
        case .stale, .notPinned, .presented, .unavailable: .orange
        case .mismatch: .red
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
