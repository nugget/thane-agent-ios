import CoreLocation
import SwiftUI

struct SharingView: View {
    @Environment(AppState.self) private var appState

    let counterparty: ThaneCounterparty

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
        .navigationTitle("Sharing with \(counterparty.displayName)")
    }

    private var recipientCard: some View {
        AppCard(title: "Recipient") {
            if let evidence = appState.presentedIdentity,
               evidence.instance.id == counterparty.id {
                NavigationLink {
                    IdentityEvidenceView(evidence: evidence)
                } label: {
                    HStack(spacing: 12) {
                        ThaneIdentityMark(identityID: evidence.instance.id, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(recipientTitle(for: evidence))
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("\(appState.identityStatusLabel) · \(evidence.instance.shortFingerprint)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if !appState.identityContinuity.permitsPrivateDelivery {
                    Label(
                        appState.identityContinuity == .mismatch
                            ? "Sharing blocked by identity mismatch"
                            : "Sharing waits for an identity pin",
                        systemImage: appState.identityContinuity == .mismatch
                            ? "exclamationmark.shield.fill"
                            : "pin.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(appState.identityContinuity == .mismatch ? .red : .orange)
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
                Text(pinnedRecipientDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label(counterparty.displayName, systemImage: "lock.shield")
                    .font(.headline)
                Text("This sharing policy is unavailable until this counterparty is pinned on this iPhone.")
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
                .disabled(!canEditSharing)
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
            .disabled(!canEditSharing)

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
            Text("Every source defaults off for \(counterparty.displayName). \(counterparty.displayName) cannot grant itself access or trigger an Apple permission prompt. Enabled data is sent only after current evidence matches this iPhone's identity pin, through the authenticated companion connection or an approved event-driven upload.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var canEditSharing: Bool {
        appState.sharingPreferences.counterpartyID == counterparty.id
            && appState.identityPinning.pin?.identityID == counterparty.id
    }

    private var pinnedRecipientDetail: String {
        if appState.identityContinuity == .mismatch {
            return "The configured endpoint presents a different identity. Delivery remains blocked while this sharing policy stays attached to \(counterparty.displayName)."
        }
        return "Current evidence is unavailable. Live requests and observation uploads remain disabled until the endpoint presents identity evidence matching \(counterparty.displayName)."
    }

    private func recipientTitle(for evidence: ThaneIdentityEvidence) -> String {
        appState.identityContinuity.permitsPrivateDelivery
            ? "Shared with pinned \(evidence.instance.name)"
            : "Presented by \(evidence.instance.name)"
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

#Preview("Sharing") {
    NavigationStack {
        SharingView(counterparty: PreviewFixtures.counterparty)
    }
    .environment(PreviewFixtures.appState())
}
