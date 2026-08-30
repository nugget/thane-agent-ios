import CoreLocation
import Foundation

@MainActor
protocol LocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var desiredAccuracy: CLLocationAccuracy { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }

    func requestWhenInUseAuthorization()
    func requestLocation()
    func startMonitoringSignificantLocationChanges()
    func stopMonitoringSignificantLocationChanges()
}

extension CLLocationManager: LocationManaging {}

@MainActor
protocol LocationAuthorizationSession: AnyObject {
    func invalidate()
}

extension CLServiceSession: LocationAuthorizationSession {}

nonisolated struct LocationSnapshot: Codable, Equatable, Sendable {
    let capturedAt: String
    let locationTimestamp: String
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let ellipsoidalAltitudeMeters: Double?
    let horizontalAccuracyMeters: Double
    let verticalAccuracyMeters: Double?
    let speedMetersPerSecond: Double?
    let speedAccuracyMetersPerSecond: Double?
    let courseDegrees: Double?
    let courseAccuracyDegrees: Double?
    let floor: Int?
    let authorization: String
    let accuracyAuthorization: String
    let simulatedBySoftware: Bool?
    let producedByAccessory: Bool?

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case locationTimestamp = "location_timestamp"
        case latitude, longitude
        case altitudeMeters = "altitude_meters"
        case ellipsoidalAltitudeMeters = "ellipsoidal_altitude_meters"
        case horizontalAccuracyMeters = "horizontal_accuracy_meters"
        case verticalAccuracyMeters = "vertical_accuracy_meters"
        case speedMetersPerSecond = "speed_meters_per_second"
        case speedAccuracyMetersPerSecond = "speed_accuracy_meters_per_second"
        case courseDegrees = "course_degrees"
        case courseAccuracyDegrees = "course_accuracy_degrees"
        case floor
        case authorization
        case accuracyAuthorization = "accuracy_authorization"
        case simulatedBySoftware = "simulated_by_software"
        case producedByAccessory = "produced_by_accessory"
    }
}

nonisolated enum LocationServiceError: PlatformServiceError, Sendable {
    case sharingDisabled
    case permissionNotRequested
    case permissionDenied
    case permissionRestricted
    case requestInProgress
    case unavailable
    case timedOut
    case unsupportedMethod(String)

    var code: String {
        switch self {
        case .sharingDisabled: "location_sharing_disabled"
        case .permissionNotRequested: "location_permission_not_requested"
        case .permissionDenied: "location_permission_denied"
        case .permissionRestricted: "location_permission_restricted"
        case .requestInProgress: "location_request_in_progress"
        case .unavailable: "location_unavailable"
        case .timedOut: "location_timed_out"
        case .unsupportedMethod: "unknown_method"
        }
    }

    var errorDescription: String? {
        switch self {
        case .sharingDisabled:
            "Location sharing is disabled in the iOS companion app."
        case .permissionNotRequested:
            "Enable Location sharing in the iOS companion before requesting location."
        case .permissionDenied:
            "Location permission is denied. It can be changed in iOS Settings."
        case .permissionRestricted:
            "Location access is restricted on this device."
        case .requestInProgress:
            "A location request is already in progress."
        case .unavailable:
            "A current location fix is unavailable."
        case .timedOut:
            "The one-time location request timed out."
        case .unsupportedMethod(let method):
            "Unsupported Location method: \(method)"
        }
    }
}

@Observable
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let manager: any LocationManaging
    private let preferences: SharingPreferences
    private let requestTimeout: Duration
    private let authorizationSessionFactory: @MainActor () -> any LocationAuthorizationSession
    private var pendingContinuation: CheckedContinuation<LocationSnapshot, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var authorizationSession: (any LocationAuthorizationSession)?
    private var reportedBackgroundUnavailable = false

    private(set) var authorizationStatus: CLAuthorizationStatus
    let isSignificantLocationChangeMonitoringAvailable: Bool
    private(set) var isBackgroundMonitoringActive = false
    var onSignificantLocation: ((LocationSnapshot) -> Void)?
    var onBackgroundLocationUnavailable: (() -> Void)?

    init(
        preferences: SharingPreferences,
        manager: any LocationManaging = CLLocationManager(),
        requestTimeout: Duration = .seconds(15),
        significantLocationChangeMonitoringAvailable: Bool = CLLocationManager
            .significantLocationChangeMonitoringAvailable(),
        authorizationSessionFactory: @escaping @MainActor () -> any LocationAuthorizationSession = {
            CLServiceSession(authorization: .always)
        }
    ) {
        self.preferences = preferences
        self.manager = manager
        self.requestTimeout = requestTimeout
        isSignificantLocationChangeMonitoringAvailable = significantLocationChangeMonitoringAvailable
        self.authorizationSessionFactory = authorizationSessionFactory
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        restoreBackgroundMonitoringIfAuthorized()
    }

    var authorizationLabel: String {
        Self.authorizationLabel(authorizationStatus)
    }

    var accuracyLabel: String? {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            Self.accuracyLabel(manager.accuracyAuthorization)
        default:
            nil
        }
    }

    /// Called only from the local toggle. A remote tool invocation never
    /// displays a system permission prompt.
    func requestWhenInUseAuthorizationIfNeeded() {
        guard preferences.locationEnabled,
              manager.authorizationStatus == .notDetermined else {
            return
        }
        manager.requestWhenInUseAuthorization()
    }

    /// Called from the local background-sharing toggle. Creating an Always
    /// service session here lets iOS present any authorization upgrade while
    /// the operator is visibly using the app; a remote request never does so.
    func setBackgroundMonitoringEnabled(_ enabled: Bool) {
        authorizationStatus = manager.authorizationStatus
        preferences.backgroundLocationEnabled = enabled
        if enabled {
            guard preferences.locationEnabled else {
                preferences.backgroundLocationEnabled = false
                return
            }
            reconcileBackgroundMonitoring(allowAuthorizationRequest: true)
            reportBackgroundUnavailableIfNeeded()
        } else {
            reportedBackgroundUnavailable = false
            stopBackgroundMonitoring(invalidateSession: true)
        }
    }

    /// Re-establishes only an already-authorized session. This is safe during
    /// a Core Location background relaunch because it cannot originate a new
    /// permission prompt.
    func restoreBackgroundMonitoringIfAuthorized() {
        authorizationStatus = manager.authorizationStatus
        guard preferences.locationEnabled, preferences.backgroundLocationEnabled else {
            return
        }
        guard authorizationStatus == .authorizedAlways else {
            stopBackgroundMonitoring(invalidateSession: false)
            reportBackgroundUnavailableIfNeeded()
            return
        }
        reconcileBackgroundMonitoring(allowAuthorizationRequest: false)
    }

    func currentLocation() async throws -> LocationSnapshot {
        try validateAccess()

        guard pendingContinuation == nil else {
            throw LocationServiceError.requestInProgress
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
                manager.requestLocation()
                let requestTimeout = self.requestTimeout
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: requestTimeout)
                    } catch {
                        return
                    }
                    self?.finish(throwing: LocationServiceError.timedOut)
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.finish(throwing: CancellationError())
            }
        }
    }

    func cancelPendingRequestAfterConsentRevocation() {
        guard !preferences.locationEnabled else { return }
        preferences.backgroundLocationEnabled = false
        stopBackgroundMonitoring(invalidateSession: true)
        finish(throwing: LocationServiceError.sharingDisabled)
    }

    func locationManager(
        _: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        do {
            try validateAccess()
        } catch {
            finish(throwing: error)
            return
        }

        guard let location = locations
            .filter({ CLLocationCoordinate2DIsValid($0.coordinate) && $0.horizontalAccuracy >= 0 })
            .max(by: { $0.timestamp < $1.timestamp }) else {
            finish(throwing: LocationServiceError.unavailable)
            return
        }

        let snapshot = Self.snapshot(
            from: location,
            capturedAt: Date(),
            authorization: authorizationStatus,
            accuracyAuthorization: manager.accuracyAuthorization
        )
        if preferences.backgroundLocationEnabled,
           authorizationStatus == .authorizedAlways {
            reportedBackgroundUnavailable = false
            onSignificantLocation?(snapshot)
        }
        if pendingContinuation != nil {
            finish(returning: snapshot)
        }
    }

    private static func snapshot(
        from location: CLLocation,
        capturedAt: Date,
        authorization: CLAuthorizationStatus,
        accuracyAuthorization: CLAccuracyAuthorization
    ) -> LocationSnapshot {
        let source = location.sourceInformation
        let hasValidAltitude = location.verticalAccuracy >= 0
        return LocationSnapshot(
            capturedAt: Self.timestampFormatter.string(from: capturedAt),
            locationTimestamp: Self.timestampFormatter.string(from: location.timestamp),
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeMeters: hasValidAltitude ? location.altitude : nil,
            ellipsoidalAltitudeMeters: hasValidAltitude ? location.ellipsoidalAltitude : nil,
            horizontalAccuracyMeters: location.horizontalAccuracy,
            verticalAccuracyMeters: hasValidAltitude ? location.verticalAccuracy : nil,
            speedMetersPerSecond: location.speed >= 0 ? location.speed : nil,
            speedAccuracyMetersPerSecond: location.speedAccuracy >= 0 ? location.speedAccuracy : nil,
            courseDegrees: location.course >= 0 ? location.course : nil,
            courseAccuracyDegrees: location.courseAccuracy >= 0 ? location.courseAccuracy : nil,
            floor: location.floor?.level,
            authorization: Self.authorizationLabel(authorization),
            accuracyAuthorization: Self.accuracyLabel(accuracyAuthorization),
            simulatedBySoftware: source?.isSimulatedBySoftware,
            producedByAccessory: source?.isProducedByAccessory
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let locationError = error as? CLError, locationError.code == .denied {
            finish(throwing: LocationServiceError.permissionDenied)
        } else {
            finish(throwing: LocationServiceError.unavailable)
        }
    }

    func locationManagerDidChangeAuthorization(_: CLLocationManager) {
        let previousStatus = authorizationStatus
        authorizationStatus = manager.authorizationStatus
        if preferences.backgroundLocationEnabled {
            if previousStatus == .authorizedAlways,
               authorizationStatus != .authorizedAlways {
                stopBackgroundMonitoring(invalidateSession: true)
                reportBackgroundUnavailableIfNeeded()
            } else {
                reconcileBackgroundMonitoring(allowAuthorizationRequest: false)
            }
        }

        guard pendingContinuation != nil else { return }
        switch authorizationStatus {
        case .denied:
            finish(throwing: LocationServiceError.permissionDenied)
        case .restricted:
            finish(throwing: LocationServiceError.permissionRestricted)
        default:
            break
        }
    }

    private func finish(returning snapshot: LocationSnapshot) {
        do {
            try validateAccess()
        } catch {
            finish(throwing: error)
            return
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(returning: snapshot)
    }

    private func finish(throwing error: Error) {
        timeoutTask?.cancel()
        timeoutTask = nil
        let continuation = pendingContinuation
        pendingContinuation = nil
        continuation?.resume(throwing: error)
    }

    private func reconcileBackgroundMonitoring(allowAuthorizationRequest: Bool) {
        guard preferences.locationEnabled, preferences.backgroundLocationEnabled else {
            stopBackgroundMonitoring(invalidateSession: true)
            return
        }

        switch authorizationStatus {
        case .authorizedAlways:
            guard isSignificantLocationChangeMonitoringAvailable else {
                stopBackgroundMonitoring(invalidateSession: true)
                reportBackgroundUnavailableIfNeeded()
                return
            }
            if authorizationSession == nil {
                authorizationSession = authorizationSessionFactory()
            }
            guard !isBackgroundMonitoringActive else { return }
            manager.startMonitoringSignificantLocationChanges()
            isBackgroundMonitoringActive = true
        case .notDetermined, .authorizedWhenInUse:
            stopBackgroundMonitoring(invalidateSession: false)
            if allowAuthorizationRequest, authorizationSession == nil {
                authorizationSession = authorizationSessionFactory()
            }
        case .denied, .restricted:
            stopBackgroundMonitoring(invalidateSession: true)
        @unknown default:
            stopBackgroundMonitoring(invalidateSession: true)
        }
    }

    private func stopBackgroundMonitoring(invalidateSession: Bool) {
        if isBackgroundMonitoringActive {
            manager.stopMonitoringSignificantLocationChanges()
            isBackgroundMonitoringActive = false
        }
        if invalidateSession {
            authorizationSession?.invalidate()
            authorizationSession = nil
        }
    }

    private func reportBackgroundUnavailableIfNeeded() {
        guard preferences.backgroundLocationEnabled,
              (authorizationStatus != .authorizedAlways
                  || !isSignificantLocationChangeMonitoringAvailable),
              !reportedBackgroundUnavailable,
              let onBackgroundLocationUnavailable else {
            return
        }
        reportedBackgroundUnavailable = true
        onBackgroundLocationUnavailable()
    }

    private func validateAccess() throws {
        guard preferences.locationEnabled else {
            throw LocationServiceError.sharingDisabled
        }

        switch authorizationStatus {
        case .notDetermined:
            throw LocationServiceError.permissionNotRequested
        case .denied:
            throw LocationServiceError.permissionDenied
        case .restricted:
            throw LocationServiceError.permissionRestricted
        case .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            throw LocationServiceError.permissionDenied
        }
    }

    private nonisolated static func authorizationLabel(
        _ status: CLAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined: "not_determined"
        case .restricted: "restricted"
        case .denied: "denied"
        case .authorizedAlways: "always"
        case .authorizedWhenInUse: "when_in_use"
        @unknown default: "unknown"
        }
    }

    private nonisolated static func accuracyLabel(
        _ authorization: CLAccuracyAuthorization
    ) -> String {
        switch authorization {
        case .fullAccuracy: "full"
        case .reducedAccuracy: "reduced"
        @unknown default: "unknown"
        }
    }
}

@MainActor
struct LocationPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["get_current_location"]
    let toolDefinitions = [
        PlatformToolDefinition.make(
            name: "ios_current_location",
            description: "Request one current location fix from the active iOS companion. This works only after the operator enables Location sharing in the app and grants iOS permission.",
            method: "get_current_location",
            tags: ["ios", "location", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {}
            }
            """
        ),
    ]

    private let service: LocationService

    init(service: LocationService) {
        self.service = service
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard method == "get_current_location" else {
            throw LocationServiceError.unsupportedMethod(method)
        }
        return try AnyCodable.fromEncodable(await service.currentLocation())
    }
}
