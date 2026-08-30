import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showingForgetConfirmation = false
    @State private var showingForgetThaneConfirmation = false
    @State private var showingIdentity = false
    @State private var showingPin = false

    var body: some View {
        Form {
            Section("Identity & Connection") {
                if let evidence = appState.presentedIdentity {
                    IdentitySummaryButton(
                        evidence: evidence,
                        status: appState.identityStatusLabel
                    ) {
                        showingIdentity = true
                    }
                } else if let pin = appState.identityPinning.pin {
                    PinnedIdentitySummaryButton(
                        pin: pin,
                        status: appState.identityStatusLabel
                    ) {
                        showingPin = true
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
                    Button(appState.identityPinning.pin == nil ? "Check Identity" : "Connect") {
                        appState.connectUsingCurrentValues()
                    }
                    .disabled(!appState.hasConnectionCredentials)
                }

                Button("Forget API Token", role: .destructive) {
                    showingForgetConfirmation = true
                }
                .disabled(appState.tokenInput.isEmpty)

                if appState.identityPinning.pin != nil || appState.identityPinning.lastError != nil {
                    Button("Forget This Thane", role: .destructive) {
                        showingForgetThaneConfirmation = true
                    }
                }
            } footer: {
                Text("The API token and identity pin are stored in this iPhone's protected Keychain. Remote servers must use HTTPS, and TLS verification is never disabled. Private delivery starts only after current evidence matches the pin.")
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
        .sheet(isPresented: $showingPin) {
            if let pin = appState.identityPinning.pin {
                IdentityPinView(pin: pin)
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
        .confirmationDialog(
            "Forget this Thane?",
            isPresented: $showingForgetThaneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget This Thane", role: .destructive) {
                Task { await appState.forgetThane() }
            }
        } message: {
            Text("The app will disconnect, remove the identity pin, and permanently discard observations queued for this Thane. The API token and local sharing choices are unchanged.")
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
