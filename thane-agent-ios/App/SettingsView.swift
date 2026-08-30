import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showingForgetConfirmation = false
    @State private var showingIdentity = false

    var body: some View {
        Form {
            Section("Identity & Connection") {
                if let evidence = appState.presentedIdentity {
                    IdentitySummaryButton(evidence: evidence) {
                        showingIdentity = true
                    }
                }

                LabeledContent("Status") {
                    Label(appState.statusTitle, systemImage: appState.statusSymbol)
                        .foregroundStyle(statusColor)
                }

                if let account = appState.connection.account {
                    LabeledContent("Account", value: account)
                }
                if let serverVersion = appState.connection.serverVersion {
                    LabeledContent("Server version", value: serverVersion)
                }
            }

            Section("Server") {
                TextField("https://thane.example.com", text: Binding(
                    get: { appState.connectionSettings.urlString },
                    set: { appState.connectionSettings.urlString = $0 }
                ))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.URL)
                .disabled(appState.hasActiveConnection)

                SecureField("API token", text: Binding(
                    get: { appState.tokenInput },
                    set: { appState.tokenInput = $0 }
                ))
                .textContentType(.password)
                .disabled(appState.hasActiveConnection)

                if appState.hasActiveConnection {
                    Text("Disconnect before editing connection credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = appState.displayedError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section {
                if appState.hasActiveConnection {
                    Button("Disconnect", role: .destructive) {
                        appState.disconnect()
                    }
                } else {
                    Button("Connect") {
                        appState.connectUsingCurrentValues()
                    }
                    .disabled(!appState.hasConnectionCredentials)
                }

                Button("Forget API Token", role: .destructive) {
                    showingForgetConfirmation = true
                }
                .disabled(appState.tokenInput.isEmpty)
            } footer: {
                Text("The API token is stored in Keychain. Remote servers must use HTTPS, and TLS verification is never disabled. Disconnecting pauses automatic connection and uploads until you connect again.")
            }

            Section("Companion") {
                LabeledContent("Client ID") {
                    Text(appState.connectionSettings.clientID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("App version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingIdentity) {
            if let evidence = appState.presentedIdentity {
                IdentityEvidenceView(evidence: evidence)
            }
        }
        .confirmationDialog(
            "Forget this API token?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget API Token", role: .destructive) {
                appState.forgetToken()
            }
        } message: {
            Text("The app will disconnect and remove the credential from Keychain. Your local sharing choices are unchanged.")
        }
    }

    private var statusColor: Color {
        switch appState.connection.state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .disconnected: .secondary
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): build
        case (nil, nil): "Unknown"
        }
    }
}
