import CoreLocation
import Foundation
import SwiftUI
import UIKit

@Observable
@MainActor
final class AppState {
    let connectionSettings: ConnectionSettings
    let sharingPreferences: SharingPreferences
    let connection: ServerConnection
    let platformRouter: PlatformServiceRouter
    let locationService: LocationService
    let observationPublisher: ObservationPublisher
    let identityService: IdentityService

    var tokenInput: String = ""
    private(set) var configurationError: String?

    private let systemContextService: SystemContextService

    init(
        connectionSettings: ConnectionSettings = ConnectionSettings(),
        sharingPreferences: SharingPreferences = SharingPreferences(),
        observationPublisher: ObservationPublisher = ObservationPublisher(),
        identityService: IdentityService = IdentityService()
    ) {
        self.connectionSettings = connectionSettings
        self.sharingPreferences = sharingPreferences
        self.observationPublisher = observationPublisher
        self.identityService = identityService

        let connection = ServerConnection()
        let router = PlatformServiceRouter()
        let systemService = SystemContextService(preferences: sharingPreferences)
        let locationService = LocationService(preferences: sharingPreferences)

        self.connection = connection
        platformRouter = router
        systemContextService = systemService
        self.locationService = locationService

        locationService.onSignificantLocation = { [weak observationPublisher] snapshot in
            observationPublisher?.publishLocation(snapshot)
        }
        locationService.onBackgroundLocationUnavailable = { [weak observationPublisher] in
            observationPublisher?.withdraw(.location)
        }
        locationService.restoreBackgroundMonitoringIfAuthorized()
        systemService.setChangeHandler { [weak self] in
            self?.publishSystemContextIfEnabled()
        }

        router.register(
            capability: "ios.system-context",
            handler: SystemContextPlatformHandler(service: systemService)
        )
        router.register(
            capability: "ios.location",
            handler: LocationPlatformHandler(service: locationService)
        )
        connection.registeredCapabilities = router.capabilities
        connection.onPlatformRequest = { [weak router] request in
            guard let router else {
                return PlatformResponse(
                    id: request.id,
                    type: "result",
                    success: false,
                    result: nil,
                    error: WSError(code: "unavailable", message: "Platform router unavailable")
                )
            }
            return await router.handle(request: request)
        }
        connection.onConnected = { [weak observationPublisher] in
            // Observation authentication resolves this client ID through the
            // durable inventory written by a successful realtime handshake.
            observationPublisher?.flush()
        }
        connection.onAuthenticationFailure = { [weak connectionSettings, weak observationPublisher] in
            connectionSettings?.isEnabled = false
            observationPublisher?.configure(baseURL: nil, token: nil, clientID: "")
        }

        do {
            tokenInput = try connectionSettings.storedToken() ?? ""
            if !tokenInput.isEmpty {
                // Re-saving migrates tokens created by older builds to the
                // after-first-unlock accessibility required for a location wake.
                try connectionSettings.saveToken(tokenInput)
            }
        } catch {
            configurationError = error.localizedDescription
        }
        configureObservationPublisher()
    }

    var statusTitle: String {
        switch connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting · \(attempt)"
        }
    }

    var statusSymbol: String {
        switch connection.state {
        case .connected: "checkmark.circle.fill"
        case .connecting, .authenticating, .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .disconnected: "circle.dashed"
        }
    }

    var hasActiveConnection: Bool {
        connection.state != .disconnected
    }

    var displayedError: String? {
        configurationError ?? connection.lastError
    }

    var hasConnectionCredentials: Bool {
        connectionSettings.serverURL != nil
            && !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var presentedIdentity: ThaneIdentityEvidence? {
        identityService.evidence(for: connectionSettings.serverURL)
    }

    func activate() {
        locationService.restoreBackgroundMonitoringIfAuthorized()
        configureObservationPublisher()
        publishSystemContextIfEnabled()
        observationPublisher.flush()
        guard connectionSettings.isEnabled,
              connection.state == .disconnected else {
            return
        }
        connectUsingCurrentValues()
    }

    func enterBackground() {
        connection.disconnect()
    }

    func connectUsingCurrentValues() {
        configurationError = nil
        guard let url = connectionSettings.serverURL else {
            configurationError = "Enter an HTTPS Thane base URL. HTTP is accepted only for loopback development."
            return
        }

        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            configurationError = "Enter a Thane API token."
            return
        }

        do {
            try connectionSettings.saveToken(token)
        } catch {
            configurationError = error.localizedDescription
            return
        }

        connectionSettings.isEnabled = true
        identityService.refresh(from: url, token: token)
        observationPublisher.configure(
            baseURL: url,
            token: token,
            clientID: connectionSettings.clientID
        )
        connection.connect(
            url: url,
            token: token,
            clientID: connectionSettings.clientID,
            clientName: "Thane for iOS"
        )
    }

    func disconnect() {
        connectionSettings.isEnabled = false
        observationPublisher.configure(baseURL: nil, token: nil, clientID: "")
        connection.disconnect()
    }

    func refreshIdentity() {
        configurationError = nil
        guard let url = connectionSettings.serverURL else {
            configurationError = "Enter a valid Thane base URL before refreshing identity evidence."
            return
        }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            configurationError = "Enter a Thane API token before refreshing identity evidence."
            return
        }
        identityService.refresh(from: url, token: token)
    }

    func forgetToken() {
        configurationError = nil
        do {
            try connectionSettings.deleteToken()
        } catch {
            configurationError = error.localizedDescription
            return
        }

        tokenInput = ""
        disconnect()
    }

    func setSystemCategory(_ category: SystemContextCategory, enabled: Bool) {
        sharingPreferences.setEnabled(enabled, for: category)
        if category == .network {
            systemContextService.setNetworkObservationEnabled(enabled)
        } else if category == .device {
            systemContextService.setDeviceObservationEnabled(enabled)
        }
        publishSystemContextIfEnabled(withdrawIfDisabled: true)
    }

    func setLocationSharing(enabled: Bool) {
        if !enabled, sharingPreferences.backgroundLocationEnabled {
            locationService.setBackgroundMonitoringEnabled(false)
            observationPublisher.withdraw(.location)
        }
        sharingPreferences.locationEnabled = enabled
        if enabled {
            locationService.requestWhenInUseAuthorizationIfNeeded()
        } else {
            locationService.cancelPendingRequestAfterConsentRevocation()
        }
    }

    func setBackgroundLocationSharing(enabled: Bool) {
        locationService.setBackgroundMonitoringEnabled(enabled)
        if !enabled {
            observationPublisher.withdraw(.location)
        }
    }

    func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func configureObservationPublisher() {
        guard connectionSettings.isEnabled else {
            observationPublisher.configure(baseURL: nil, token: nil, clientID: "")
            return
        }
        observationPublisher.configure(
            baseURL: connectionSettings.serverURL,
            token: tokenInput,
            clientID: connectionSettings.clientID
        )
    }

    private func publishSystemContextIfEnabled(withdrawIfDisabled: Bool = false) {
        do {
            observationPublisher.publishSystemContext(try systemContextService.snapshot())
        } catch SystemContextServiceError.noCategoriesEnabled {
            if withdrawIfDisabled {
                observationPublisher.withdraw(.systemContext)
            }
        } catch {
            configurationError = error.localizedDescription
        }
    }
}
