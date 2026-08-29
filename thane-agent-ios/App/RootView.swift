import CoreLocation
import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    connectionSection
                    sharingSection
                    availabilitySection
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Thane")
        }
    }

    private var connectionSection: some View {
        section(title: "Thane Connection") {
            HStack {
                Text("Status")
                Spacer()
                Label(appState.statusTitle, systemImage: appState.statusSymbol)
                    .foregroundStyle(statusColor)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Server")
                    .font(.subheadline.weight(.medium))
                TextField("https://thane.example.com", text: Binding(
                    get: { appState.connectionSettings.urlString },
                    set: { appState.connectionSettings.urlString = $0 }
                ))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("API Token")
                    .font(.subheadline.weight(.medium))
                SecureField("Stored in Keychain", text: Binding(
                    get: { appState.tokenInput },
                    set: { appState.tokenInput = $0 }
                ))
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)
            }

            if let account = appState.connection.account {
                HStack {
                    Text("Account")
                    Spacer()
                    Text(account)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = appState.displayedError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Group {
                if appState.isConnected {
                    Button("Disconnect", role: .destructive) {
                        appState.disconnect()
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button("Connect") {
                        appState.connectUsingCurrentValues()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)

            Text("The token is stored in Keychain. Remote servers must use HTTPS, and TLS verification is never disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sharingSection: some View {
        section(title: "Shared Data") {
            ForEach(Array(SystemContextCategory.allCases.enumerated()), id: \.element.id) { index, category in
                if index > 0 {
                    Divider()
                }
                Toggle(isOn: Binding(
                    get: { appState.sharingPreferences.isEnabled(category) },
                    set: { appState.setSystemCategory(category, enabled: $0) }
                )) {
                    preferenceLabel(title: category.title, detail: category.detail)
                }
            }

            Divider()

            Toggle(isOn: Binding(
                get: { appState.sharingPreferences.locationEnabled },
                set: { appState.setLocationSharing(enabled: $0) }
            )) {
                preferenceLabel(
                    title: "Current Location",
                    detail: "Shares one Core Location fix per request, including accuracy and sensor provenance."
                )
            }

            if appState.sharingPreferences.locationEnabled {
                Divider()

                HStack {
                    Text("Location Permission")
                    Spacer()
                    Text(locationPermissionLabel)
                        .foregroundStyle(locationPermissionColor)
                        .multilineTextAlignment(.trailing)
                }

                if locationPermissionNeedsSettings {
                    Button("Open iOS Settings") {
                        appState.openIOSSettings()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                }
            }

            Text("Every source defaults off. Thane can request enabled data only while this app is active and authenticated.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var availabilitySection: some View {
        section(title: "Availability") {
            Label("Foreground only", systemImage: "iphone")
            Text("iOS suspends general-purpose apps in the background. This first version reconnects when active and makes no always-on availability claim.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(18)
            .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
    }

    private func preferenceLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusColor: Color {
        switch appState.connection.state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .disconnected: .secondary
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
}

#Preview {
    RootView()
        .environment(AppState())
}
