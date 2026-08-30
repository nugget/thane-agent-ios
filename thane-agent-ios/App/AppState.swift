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
    let identityPinning: IdentityPinningService

    var tokenInput: String = ""
    private(set) var configurationError: String?

    private let systemContextService: SystemContextService

    init(
        connectionSettings: ConnectionSettings = ConnectionSettings(),
        sharingPreferences: SharingPreferences = SharingPreferences(),
        observationPublisher: ObservationPublisher = ObservationPublisher(),
        identityService: IdentityService = IdentityService(),
        identityPinning: IdentityPinningService = IdentityPinningService()
    ) {
        self.connectionSettings = connectionSettings
        self.sharingPreferences = sharingPreferences
        self.observationPublisher = observationPublisher
        self.identityService = identityService
        self.identityPinning = identityPinning

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
        connection.onAuthenticationFailure = { [weak self] in
            self?.connectionSettings.isEnabled = false
            self?.suspendObservationDelivery()
        }
        identityService.onEvidenceUpdated = { [weak self] _ in
            self?.reconcileIdentityBoundary()
        }
        identityService.onRefreshFailed = { [weak self] in
            self?.reconcileIdentityBoundary()
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
        if connection.state == .disconnected {
            if identityService.isRefreshing { return "Checking Identity" }
            switch identityContinuity {
            case .presented: return "Awaiting Pin"
            case .mismatch: return "Identity Mismatch"
            case .unavailable where connectionSettings.isEnabled: return "Identity Unavailable"
            default: break
            }
        }
        return switch connection.state {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .authenticating: "Authenticating"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting · \(attempt)"
        }
    }

    var statusSymbol: String {
        if connection.state == .disconnected {
            if identityService.isRefreshing { return "person.badge.shield.checkmark" }
            switch identityContinuity {
            case .presented: return "pin.circle"
            case .mismatch: return "exclamationmark.shield.fill"
            case .unavailable where connectionSettings.isEnabled: return "questionmark.diamond"
            default: break
            }
        }
        return switch connection.state {
        case .connected: "checkmark.circle.fill"
        case .connecting, .authenticating, .reconnecting: "arrow.trianglehead.2.clockwise.rotate.90"
        case .disconnected: "circle.dashed"
        }
    }

    var hasActiveConnection: Bool {
        connection.state != .disconnected
    }

    var displayedError: String? {
        configurationError ?? identityPinning.lastError ?? connection.lastError
    }

    var hasConnectionCredentials: Bool {
        connectionSettings.serverURL != nil
            && !tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var presentedIdentity: ThaneIdentityEvidence? {
        identityService.evidence(for: connectionSettings.serverURL)
    }

    var identityContinuity: IdentityContinuityState {
        IdentityContinuityState.evaluate(
            pin: identityPinning.pin,
            evidence: presentedIdentity
        )
    }

    var identityStatusLabel: String {
        switch identityContinuity {
        case .notPinned: "Not pinned"
        case .presented: "Presented · review before pinning"
        case .matching: "Pinned and matching"
        case .stale: "Pinned match · evidence is stale"
        case .unavailable: "Pinned · current evidence unavailable"
        case .mismatch: "Identity mismatch · delivery blocked"
        }
    }

    var hasVerifiedReportedCoreChecks: Bool {
        guard let evidence = presentedIdentity else { return false }
        return evidence.core.verification.admission.isVerified
            && evidence.core.verification.head.isVerified
    }

    func activate() {
        locationService.restoreBackgroundMonitoringIfAuthorized()
        // A foreground transition must revalidate the current endpoint and
        // token before either transport can release private data.
        suspendPrivateDelivery()
        publishSystemContextIfEnabled()
        guard connectionSettings.isEnabled else { return }
        refreshIdentityForConfiguredConnection()
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
        suspendPrivateDelivery()
        identityService.refresh(from: url, token: token)
    }

    func disconnect() {
        connectionSettings.isEnabled = false
        suspendPrivateDelivery()
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
        suspendPrivateDelivery()
        identityService.refresh(from: url, token: token)
    }

    func pinPresentedIdentity() {
        configurationError = nil
        guard let evidence = presentedIdentity else {
            configurationError = "Refresh identity evidence before pinning this Thane."
            return
        }
        do {
            try identityPinning.pin(evidence)
        } catch {
            configurationError = error.localizedDescription
            return
        }
        reconcileIdentityBoundary()
    }

    func forgetThane() async {
        configurationError = nil
        connectionSettings.isEnabled = false
        connection.disconnect()
        do {
            try await observationPublisher.discardAllPending()
            try identityPinning.forget()
        } catch {
            configurationError = error.localizedDescription
        }
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
        guard let pin = identityPinning.pin else {
            observationPublisher.configure(
                baseURL: nil,
                token: nil,
                clientID: "",
                identityID: nil
            )
            return
        }
        guard connectionSettings.isEnabled,
              identityContinuity.permitsPrivateDelivery else {
            observationPublisher.configure(
                baseURL: nil,
                token: nil,
                clientID: "",
                identityID: pin.identityID
            )
            return
        }
        observationPublisher.configure(
            baseURL: connectionSettings.serverURL,
            token: tokenInput,
            clientID: connectionSettings.clientID,
            identityID: pin.identityID
        )
    }

    private func refreshIdentityForConfiguredConnection() {
        guard let url = connectionSettings.serverURL else { return }
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        suspendPrivateDelivery()
        identityService.refresh(from: url, token: token)
    }

    private func reconcileIdentityBoundary() {
        guard connectionSettings.isEnabled else {
            configureObservationPublisher()
            return
        }
        guard identityContinuity.permitsPrivateDelivery,
              let url = connectionSettings.serverURL else {
            suspendPrivateDelivery()
            if identityContinuity == .mismatch {
                configurationError = "The presented Thane identity does not match this iPhone's pin. Private delivery is blocked."
            }
            return
        }
        configurationError = nil
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        establishMatchedConnection(url: url, token: token)
    }

    private func establishMatchedConnection(url: URL, token: String) {
        configureObservationPublisher()
        publishSystemContextIfEnabled()
        observationPublisher.flush()
        guard connection.state == .disconnected else { return }
        connection.connect(
            url: url,
            token: token,
            clientID: connectionSettings.clientID,
            clientName: "Thane for iOS"
        )
    }

    private func suspendPrivateDelivery() {
        suspendObservationDelivery()
        connection.disconnect()
    }

    private func suspendObservationDelivery() {
        observationPublisher.configure(
            baseURL: nil,
            token: nil,
            clientID: "",
            identityID: identityPinning.pin?.identityID
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
