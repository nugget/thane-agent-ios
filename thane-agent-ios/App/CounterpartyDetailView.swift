import SwiftUI

struct CounterpartyDetailView: View {
    @Environment(AppState.self) private var appState

    let counterparty: ThaneCounterparty

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                identityCard
                sharingCard
                availabilityCard
                activityCard
                errorCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(counterparty.displayName)
    }

    @ViewBuilder
    private var identityCard: some View {
        AppCard(title: "Identity") {
            if let evidence = appState.presentedIdentity,
               evidence.instance.id == counterparty.id {
                NavigationLink {
                    IdentityEvidenceView(evidence: evidence)
                } label: {
                    IdentitySummary(
                        evidence: evidence,
                        status: appState.identityStatusLabel
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows cryptographic identity and core evidence")

                switch appState.identityContinuity {
                case .presented:
                    Label("Review the evidence before pinning", systemImage: "pin.circle")
                        .font(.headline)
                    Text("Private requests and observation uploads remain off until you pin this identity on this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        IdentityEvidenceView(evidence: evidence)
                    } label: {
                        Text("Review & Pin")
                    }
                        .buttonStyle(.borderedProminent)
                case .mismatch:
                    Label("Private delivery blocked", systemImage: "exclamationmark.shield.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Text("The instance ID, signing key, or channel CA differs from this iPhone's pin. Compare the exact values before changing identities.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .stale:
                    Label("Identity matches; evidence is stale", systemImage: "clock.badge.exclamationmark")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Button("Refresh Evidence") { appState.refreshIdentity() }
                        .buttonStyle(.bordered)
                case .matching:
                    Label(
                        appState.hasVerifiedReportedCoreChecks
                            ? "Core checks reported verified"
                            : "Core evidence includes warnings",
                        systemImage: appState.hasVerifiedReportedCoreChecks
                            ? "checkmark.seal.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(appState.hasVerifiedReportedCoreChecks ? .green : .orange)
                case .notPinned, .unavailable:
                    EmptyView()
                }
            } else if let pin = appState.identityPinning.pin,
                      pin.identityID == counterparty.id {
                NavigationLink {
                    IdentityPinView(pin: pin)
                } label: {
                    HStack {
                        PinnedIdentitySummary(
                            pin: pin,
                            status: appState.identityStatusLabel
                        )
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows the identity pinned on this iPhone")

                if appState.identityService.isRefreshing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading current identity evidence")
                            .font(.headline)
                    }
                } else {
                    if appState.identityContinuity == .mismatch {
                        Label("Configured endpoint presents a different identity", systemImage: "exclamationmark.shield.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text("Private delivery remains attached to \(counterparty.displayName) and is blocked until the endpoint presents matching evidence.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Label("Current identity evidence is unavailable", systemImage: "questionmark.diamond")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Private requests and observation uploads remain disabled until the configured endpoint presents identity evidence that matches this pin.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Refresh Identity") { appState.refreshIdentity() }
                        .buttonStyle(.bordered)
                }
            } else if appState.identityService.isRefreshing {
                HStack(spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reading identity evidence")
                            .font(.headline)
                        Text("The companion connection can continue while this loads.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else if appState.hasConnectionCredentials {
                Label("Identity evidence is not available yet", systemImage: "person.badge.shield.checkmark")
                    .font(.headline)

                Text("This does not interrupt live requests or background observation delivery. Refresh to ask \(counterparty.displayName) for current core evidence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Refresh Identity") {
                    appState.refreshIdentity()
                }
                .buttonStyle(.bordered)
            } else {
                Label("Connection unavailable", systemImage: "link.badge.plus")
                    .font(.headline)
                Text("Manage this connection from Settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sharingCard: some View {
        AppCard(title: "Sharing") {
            NavigationLink {
                SharingView(counterparty: counterparty)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "hand.raised.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Shared Information")
                            .font(.headline)
                        Text(sharingSummary)
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
        }
    }

    private var availabilityCard: some View {
        AppCard(title: "Availability") {
            OperationalRow(
                title: "Live requests",
                value: appState.statusTitle,
                systemImage: appState.statusSymbol,
                color: connectionColor
            )

            Divider()

            OperationalRow(
                title: "Background",
                value: backgroundAvailability,
                systemImage: "location.fill",
                color: backgroundAvailabilityColor
            )

            Text("Live tools are available while the app is open and identity evidence matches this iPhone's pin. Significant location changes can produce short best-effort uploads to that same identity when separately enabled; iOS controls their timing.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var activityCard: some View {
        AppCard(title: "Delivery") {
            OperationalRow(
                title: "Waiting",
                value: pendingDeliveryLabel,
                systemImage: appState.observationPublisher.pendingCount > 0 ? "tray.full" : "tray"
            )

            Divider()

            OperationalRow(
                title: "Last publish",
                value: lastPublishedLabel,
                systemImage: "arrow.up.circle"
            )
        }
    }

    @ViewBuilder
    private var errorCard: some View {
        let identityError = appState.identityService.sourceURL == appState.connectionSettings.serverURL
            ? appState.identityService.lastError
            : nil

        if let connectionError = appState.displayedError {
            AppCard {
                Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } else if let publishError = appState.observationPublisher.lastError {
            AppCard {
                Label(publishError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else if let identityError {
            AppCard {
                Label("Identity evidence unavailable", systemImage: "person.badge.shield.checkmark")
                    .font(.headline)
                Text(identityError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try Again") {
                    appState.refreshIdentity()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var connectionColor: Color {
        switch appState.connection.state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .disconnected: .secondary
        }
    }

    private var backgroundAvailability: String {
        guard appState.sharingPreferences.backgroundLocationEnabled else {
            return "Not enabled"
        }
        guard appState.locationService.isSignificantLocationChangeMonitoringAvailable else {
            return "Unavailable on this device"
        }
        return appState.locationService.isBackgroundMonitoringActive
            ? "Significant changes enabled"
            : "Needs Always permission"
    }

    private var backgroundAvailabilityColor: Color {
        guard appState.sharingPreferences.backgroundLocationEnabled else { return .secondary }
        return appState.locationService.isBackgroundMonitoringActive ? .green : .orange
    }

    private var lastPublishedLabel: String {
        guard let date = appState.observationPublisher.lastPublishedAt else { return "No publish this run" }
        return date.formatted(.relative(presentation: .named))
    }

    private var pendingDeliveryLabel: String {
        let count = appState.observationPublisher.pendingCount
        return count == 0 ? "None" : "\(count) update kind\(count == 1 ? "" : "s")"
    }

    private var sharingSummary: String {
        guard appState.sharingPreferences.counterpartyID == counterparty.id else {
            return "Unavailable until this identity is pinned"
        }
        let systemCount = appState.sharingPreferences.enabledSystemCategories.count
        let count = systemCount + (appState.sharingPreferences.locationEnabled ? 1 : 0)
        return count == 0 ? "Nothing enabled" : "\(count) source\(count == 1 ? "" : "s") enabled"
    }
}
