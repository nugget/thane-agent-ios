import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("Companion App") {
                NavigationLink {
                    AppSettingsView()
                } label: {
                    LabeledContent {
                        Text(appState.appPreferences.appearance.title)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("App Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }

            Section {
                if appState.configuredConnections.isEmpty {
                    NavigationLink {
                        AgentSettingsView()
                    } label: {
                        Label("Add Agent", systemImage: "person.crop.circle.badge.plus")
                    }
                } else {
                    ForEach(appState.configuredConnections) { connection in
                        NavigationLink {
                            AgentSettingsView()
                        } label: {
                            ConnectionRow(connection: connection)
                        }
                    }
                }
            } header: {
                Text("Agents")
            } footer: {
                Text("Each agent owns its identity, sharing policy, and connection settings. Adding or removing a connection stays within that agent's settings.")
            }

            Section("About") {
                LabeledContent("App version", value: appVersion)
            }
        }
        .navigationTitle("Settings")
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

private struct AppSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: Binding(
                    get: { appState.appPreferences.appearance },
                    set: { appState.appPreferences.appearance = $0 }
                )) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Label(appearance.title, systemImage: appearance.systemImage)
                            .tag(appearance)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Appearance")
            } footer: {
                Text("Automatic follows this iPhone's current Light or Dark appearance.")
            }
        }
        .navigationTitle("App Settings")
    }
}

private extension AppAppearance {
    var systemImage: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}

private struct ConnectionRow: View {
    @Environment(AppState.self) private var appState

    let connection: ConfiguredThaneConnection

    var body: some View {
        HStack(spacing: 12) {
            if let counterparty = connection.counterparty {
                ThaneIdentityMark(identityID: counterparty.id, size: 44)
            } else {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.title)
                    .frame(width: 44, height: 44)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(connection.counterparty?.displayName ?? connectionHost)
                    .font(.headline)
                Text(connection.counterparty == nil ? "Identity not pinned" : appState.identityStatusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if connection.counterparty != nil {
                    Text(connectionHost)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var connectionHost: String {
        connection.endpoint?.host()
            ?? appState.connectionSettings.urlString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? "Unconfigured Agent"
    }
}

private struct ConnectionStatusSection: View {
    let statusTitle: String
    let statusSymbol: String
    let statusColor: Color
    let account: String?
    let serverVersion: String?
    let serverStartedAt: Date?
    let protocolVersion: String?

    var body: some View {
        Section("Connection Status") {
            HStack(alignment: .firstTextBaseline) {
                Text("Status")
                Spacer(minLength: 16)
                HStack(spacing: 6) {
                    Image(systemName: statusSymbol)
                    Text(statusTitle)
                }
                .fixedSize(horizontal: true, vertical: true)
                .foregroundStyle(statusColor)
            }
            .accessibilityElement(children: .combine)

            if let account {
                LabeledContent("Account", value: account)
            }
            if let serverVersion {
                LabeledContent("Server version", value: serverVersion)
            }
            if let serverStartedAt {
                LabeledContent("Uptime") {
                    Text(serverStartedAt, style: .timer)
                        .monospacedDigit()
                }
            }
            if let protocolVersion {
                LabeledContent("Protocol version", value: protocolVersion)
            }
        }
    }
}

private struct AgentSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var urlString = ""
    @State private var token = ""
    @State private var hasLoadedValues = false
    @State private var showingForgetTokenConfirmation = false
    @State private var showingForgetThaneConfirmation = false
    @State private var showingRemovalConfirmation = false

    var body: some View {
        Form {
            if let counterparty = appState.counterparty {
                Section("Agent") {
                    HStack(spacing: 12) {
                        ThaneIdentityMark(identityID: counterparty.id, size: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(counterparty.displayName)
                                .font(.headline)
                            Text(counterparty.shortFingerprint)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(appState.identityStatusLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Information & Access") {
                    NavigationLink {
                        identityDetail(for: counterparty)
                    } label: {
                        LabeledContent {
                            Text(appState.identityStatusLabel)
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Identity & Trust", systemImage: "person.badge.shield.checkmark")
                        }
                    }

                    NavigationLink {
                        SharingView(counterparty: counterparty)
                    } label: {
                        LabeledContent {
                            Text(sharingSummary(for: counterparty))
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Shared Information", systemImage: "hand.raised.fill")
                        }
                    }
                }
            }

            ConnectionStatusSection(
                statusTitle: appState.statusTitle,
                statusSymbol: appState.statusSymbol,
                statusColor: statusColor,
                account: appState.connection.account,
                serverVersion: appState.connection.serverVersion,
                serverStartedAt: appState.connection.serverStartedAt,
                protocolVersion: appState.connection.protocolVersion
            )

            Section("Configuration") {
                TextField("https://thane.example.com", text: $urlString)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .disabled(appState.hasActiveConnection)

                SecureField("API token", text: $token)
                    .textContentType(.password)
                    .disabled(appState.hasActiveConnection)

                if appState.hasActiveConnection {
                    Text("Disconnect before editing connection credentials.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Pairwise Client ID") {
                    Text(appState.connectionSettings.pairwiseClientID)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            } header: {
                Text("Connection Privacy")
            } footer: {
                Text("This random identifier is stable for reconnecting to this counterparty and is never reused for another agent connection.")
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
                        applyDraftAndConnect()
                    }
                    .disabled(!draftHasCredentials)
                }

                Button("Forget API Token", role: .destructive) {
                    showingForgetTokenConfirmation = true
                }
                .disabled(appState.tokenInput.isEmpty)

                if appState.identityPinning.pin != nil || appState.identityPinning.lastError != nil {
                    Button("Forget Identity Pin", role: .destructive) {
                        showingForgetThaneConfirmation = true
                    }
                }
            } footer: {
                Text("The API token and identity pin are stored in this iPhone's protected Keychain. Private delivery starts only after current evidence matches the pin.")
            }

            if appState.hasConnectionConfiguration {
                Section {
                    Button("Remove Connection", role: .destructive) {
                        showingRemovalConfirmation = true
                    }
                } footer: {
                    Text("Removal also deletes this counterparty's sharing choices and queued observations from this iPhone.")
                }
            }
        }
        .navigationTitle(appState.counterparty == nil ? "Add Agent" : "Agent Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadValuesIfNeeded)
        .onChange(of: appState.connectionSettings.urlString) { _, newValue in
            urlString = newValue
        }
        .onChange(of: appState.tokenInput) { _, newValue in
            token = newValue
        }
        .confirmationDialog(
            "Forget this API token?",
            isPresented: $showingForgetTokenConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget API Token", role: .destructive) {
                appState.forgetToken()
                token = ""
            }
        } message: {
            Text("The app will disconnect and remove the credential from Keychain. This counterparty's sharing choices are unchanged.")
        }
        .confirmationDialog(
            "Forget this identity pin?",
            isPresented: $showingForgetThaneConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget Identity Pin", role: .destructive) {
                Task { await appState.forgetThane() }
            }
        } message: {
            Text("The app will disconnect, remove the identity pin, and discard queued observations. Connection credentials and this counterparty's saved sharing choices are unchanged.")
        }
        .confirmationDialog(
            "Remove this agent connection?",
            isPresented: $showingRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Connection", role: .destructive) {
                Task {
                    await appState.removeConnection()
                    if !appState.hasConnectionConfiguration {
                        dismiss()
                    }
                }
            }
        } message: {
            Text("The API token, identity pin, sharing choices, and queued observations for this agent will be removed from this iPhone.")
        }
    }

    private var statusColor: Color {
        switch appState.connection.state {
        case .connected: .green
        case .connecting, .authenticating, .reconnecting: .orange
        case .disconnected: .secondary
        }
    }

    private var draftHasCredentials: Bool {
        ServerAddress.parse(urlString) != nil
            && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func loadValuesIfNeeded() {
        guard !hasLoadedValues else { return }
        urlString = appState.connectionSettings.urlString
        token = appState.tokenInput
        hasLoadedValues = true
    }

    private func applyDraftAndConnect() {
        appState.connectionSettings.urlString = urlString
        appState.tokenInput = token
        appState.connectUsingCurrentValues()
    }

    @ViewBuilder
    private func identityDetail(for counterparty: ThaneCounterparty) -> some View {
        if let evidence = appState.presentedIdentity,
           evidence.instance.id == counterparty.id {
            IdentityEvidenceView(evidence: evidence)
        } else if let pin = appState.identityPinning.pin,
                  pin.identityID == counterparty.id {
            IdentityPinView(pin: pin)
        } else {
            ContentUnavailableView(
                "Identity Unavailable",
                systemImage: "person.badge.shield.checkmark",
                description: Text("No current or pinned identity evidence is available for this agent.")
            )
            .navigationTitle("Identity")
        }
    }

    private func sharingSummary(for counterparty: ThaneCounterparty) -> String {
        guard appState.sharingPreferences.counterpartyID == counterparty.id else {
            return "Unavailable"
        }
        let systemCount = appState.sharingPreferences.enabledSystemCategories.count
        let count = systemCount + (appState.sharingPreferences.locationEnabled ? 1 : 0)
        return count == 0 ? "Nothing enabled" : "\(count) source\(count == 1 ? "" : "s") enabled"
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#if DEBUG
#Preview("Settings") {
    NavigationStack {
        SettingsView()
    }
    .environment(PreviewFixtures.appState())
}

#Preview("App Settings") {
    NavigationStack {
        AppSettingsView()
    }
    .environment(PreviewFixtures.appState())
}

#Preview("Agent Settings") {
    NavigationStack {
        AgentSettingsView()
    }
    .environment(PreviewFixtures.appState())
}

#Preview("Connected Status") {
    Form {
        ConnectionStatusSection(
            statusTitle: "Connected",
            statusSymbol: "checkmark.circle.fill",
            statusColor: .green,
            account: "mcphone",
            serverVersion: "v0.10.3-330-g56f345f8",
            serverStartedAt: Date().addingTimeInterval(-7_423),
            protocolVersion: "0.1.0"
        )
    }
}
#endif
