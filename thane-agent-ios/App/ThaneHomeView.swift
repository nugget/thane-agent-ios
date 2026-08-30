import SwiftUI

struct ThaneHomeView: View {
    @Environment(AppState.self) private var appState
    @State private var showingIdentity = false
    @State private var showingPin = false

    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                identityCard
                availabilityCard
                activityCard
                errorCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Thane")
        .sheet(isPresented: $showingIdentity) {
            if let evidence = appState.presentedIdentity {
                IdentityEvidenceView(evidence: evidence)
            }
        }
        .sheet(isPresented: $showingPin) {
            if let pin = appState.identityPinning.pin {
                IdentityPinView(pin: pin)
            }
        }
    }

    @ViewBuilder
    private var identityCard: some View {
        AppCard(title: "This Thane") {
            if let evidence = appState.presentedIdentity {
                IdentitySummaryButton(
                    evidence: evidence,
                    status: appState.identityStatusLabel
                ) {
                    showingIdentity = true
                }

                switch appState.identityContinuity {
                case .presented:
                    Label("Review the evidence before pinning", systemImage: "pin.circle")
                        .font(.headline)
                    Text("Private requests and observation uploads remain off until you pin this identity on this iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Review & Pin") { showingIdentity = true }
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
            } else if let pin = appState.identityPinning.pin {
                PinnedIdentitySummaryButton(
                    pin: pin,
                    status: appState.identityStatusLabel
                ) {
                    showingPin = true
                }

                if appState.identityService.isRefreshing {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Reading current identity evidence")
                            .font(.headline)
                    }
                } else {
                    Label("Current identity evidence is unavailable", systemImage: "questionmark.diamond")
                        .font(.headline)
                        .foregroundStyle(.orange)
                    Text("Private requests and observation uploads remain disabled until the configured endpoint presents identity evidence that matches this pin.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

                Text("This does not interrupt live requests or background observation delivery. Refresh to ask the configured Thane for its current core evidence.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Refresh Identity") {
                    appState.refreshIdentity()
                }
                .buttonStyle(.bordered)
            } else {
                Label("Connect your Thane", systemImage: "link.badge.plus")
                    .font(.headline)
                Text("Add the server and API token once. Routine status and sharing controls then stay separate from credentials.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Open Settings", action: openSettings)
                    .buttonStyle(.borderedProminent)
            }
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
                Button("Review Connection", action: openSettings)
                    .buttonStyle(.bordered)
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
}
