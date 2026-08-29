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

    var tokenInput: String = ""
    private(set) var configurationError: String?

    private let systemContextService: SystemContextService

    init(
        connectionSettings: ConnectionSettings = ConnectionSettings(),
        sharingPreferences: SharingPreferences = SharingPreferences()
    ) {
        self.connectionSettings = connectionSettings
        self.sharingPreferences = sharingPreferences

        let connection = ServerConnection()
        let router = PlatformServiceRouter()
        let systemService = SystemContextService(preferences: sharingPreferences)
        let locationService = LocationService(preferences: sharingPreferences)

        self.connection = connection
        platformRouter = router
        systemContextService = systemService
        self.locationService = locationService

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

        do {
            tokenInput = try connectionSettings.storedToken() ?? ""
        } catch {
            configurationError = error.localizedDescription
        }
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

    var isConnected: Bool {
        connection.state == .connected
    }

    var displayedError: String? {
        configurationError ?? connection.lastError
    }

    func activate() {
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
        connection.connect(
            url: url,
            token: token,
            clientID: connectionSettings.clientID,
            clientName: "Thane for iOS"
        )
    }

    func disconnect() {
        connectionSettings.isEnabled = false
        connection.disconnect()
    }

    func setSystemCategory(_ category: SystemContextCategory, enabled: Bool) {
        sharingPreferences.setEnabled(enabled, for: category)
        if category == .network {
            systemContextService.setNetworkObservationEnabled(enabled)
        }
    }

    func setLocationSharing(enabled: Bool) {
        sharingPreferences.locationEnabled = enabled
        if enabled {
            locationService.requestWhenInUseAuthorizationIfNeeded()
        }
    }

    func openIOSSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
