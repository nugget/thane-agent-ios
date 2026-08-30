import CoreLocation
import SwiftUI

struct ContextView: View {
    @Environment(AppState.self) private var appState
    @State private var showingIdentity = false

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                recipientCard
                systemContextCard
                locationCard
                disclosureCard
            }
            .padding(.horizontal)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Context")
        .sheet(isPresented: $showingIdentity) {
            if let evidence = appState.presentedIdentity {
                IdentityEvidenceView(evidence: evidence)
            }
        }
    }

    private var recipientCard: some View {
        AppCard(title: "Recipient") {
            if let evidence = appState.presentedIdentity {
                Button {
                    showingIdentity = true
                } label: {
                    HStack(spacing: 12) {
                        ThaneIdentityMark(identityID: evidence.instance.id, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shared with \(evidence.instance.name)")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Presented identity · \(evidence.instance.shortFingerprint)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Label("Shared with the configured Thane", systemImage: "lock.shield")
                    .font(.headline)
                Text("Identity evidence will appear here when it is available from the configured endpoint.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemContextCard: some View {
        AppCard(title: "System Context") {
            ForEach(Array(SystemContextCategory.allCases.enumerated()), id: \.element.id) { index, category in
                if index > 0 { Divider() }
                Toggle(isOn: Binding(
                    get: { appState.sharingPreferences.isEnabled(category) },
                    set: { appState.setSystemCategory(category, enabled: $0) }
                )) {
                    PreferenceLabel(title: category.title, detail: category.detail)
                }
            }
        }
    }

    private var locationCard: some View {
        AppCard(title: "Location") {
            Toggle(isOn: Binding(
                get: { appState.sharingPreferences.locationEnabled },
                set: { appState.setLocationSharing(enabled: $0) }
            )) {
                PreferenceLabel(
                    title: "Current Location",
                    detail: "Shares one Core Location fix per request, including accuracy and sensor provenance."
                )
            }

            if appState.sharingPreferences.locationEnabled {
                Divider()

                Toggle(isOn: Binding(
                    get: { appState.sharingPreferences.backgroundLocationEnabled },
                    set: { appState.setBackgroundLocationSharing(enabled: $0) }
                )) {
                    PreferenceLabel(
                        title: "Background Location Updates",
                        detail: "Publishes the latest snapshot when iOS reports a significant location change. This is not continuous tracking."
                    )
                }
                .disabled(appState.locationService.authorizationStatus == .notDetermined)

                Divider()

                OperationalRow(
                    title: "Permission",
                    value: locationPermissionLabel,
                    systemImage: "location.circle",
                    color: locationPermissionColor
                )

                if appState.sharingPreferences.backgroundLocationEnabled {
                    OperationalRow(
                        title: "Monitor",
                        value: backgroundMonitorLabel,
                        systemImage: "wave.3.right.circle",
                        color: backgroundMonitorColor
                    )
                }

                if locationPermissionNeedsSettings || backgroundPermissionNeedsSettings {
                    Button("Open iOS Settings") {
                        appState.openIOSSettings()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var disclosureCard: some View {
        AppCard {
            Label("Controlled on this iPhone", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("Every source defaults off. Thane cannot grant itself access or trigger an Apple permission prompt. Enabled data is sent only through the authenticated companion connection or an approved event-driven upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var locationPermissionLabel: String {
        let authorization = appState.locationService.authorizationLabel
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
        if let accuracy = appState.locationService.accuracyLabel {
            return "\(authorization) · \(accuracy.capitalized) accuracy"
        }
        return authorization
    }

    private var locationPermissionColor: Color {
        switch appState.locationService.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .green
        case .notDetermined: .orange
        case .denied, .restricted: .red
        @unknown default: .secondary
        }
    }

    private var locationPermissionNeedsSettings: Bool {
        switch appState.locationService.authorizationStatus {
        case .denied, .restricted: true
        default: false
        }
    }

    private var backgroundPermissionNeedsSettings: Bool {
        appState.sharingPreferences.backgroundLocationEnabled
            && appState.locationService.authorizationStatus != .authorizedAlways
            && appState.locationService.authorizationStatus != .notDetermined
    }

    private var backgroundMonitorLabel: String {
        if !appState.locationService.isSignificantLocationChangeMonitoringAvailable {
            return "Unavailable on this device"
        }
        return appState.locationService.isBackgroundMonitoringActive
            ? "Active"
            : "Waiting for Always permission"
    }

    private var backgroundMonitorColor: Color {
        if !appState.locationService.isSignificantLocationChangeMonitoringAvailable {
            return .red
        }
        return appState.locationService.isBackgroundMonitoringActive ? .green : .orange
    }
}
