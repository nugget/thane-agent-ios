import SwiftUI

struct ThaneHomeView: View {
    @Environment(AppState.self) private var appState
    @State private var showingIdentity = false

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
    }

    @ViewBuilder
    private var identityCard: some View {
        AppCard(title: "This Thane") {
            if let evidence = appState.presentedIdentity {
                IdentitySummaryButton(evidence: evidence) {
                    showingIdentity = true
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

            Text("Live tools are available while the app is open. Significant location changes can produce short best-effort uploads when separately enabled; iOS controls their timing.")
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
