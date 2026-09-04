import CoreLocation
import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Location service")
@MainActor
struct LocationServiceTests {
    @Test("Default-off access never starts Core Location")
    func defaultOff() async throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        await expectLocationError("location_sharing_disabled") {
            try await service.currentLocation()
        }
        #expect(manager.requestLocationCount == 0)
    }

    @Test("Permission prompts require an enabled local preference")
    func permissionPromptGate() throws {
        let fixture = try PreferencesFixture()
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .notDetermined)
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        service.requestWhenInUseAuthorizationIfNeeded()
        #expect(manager.authorizationRequestCount == 0)

        fixture.preferences.locationEnabled = true
        service.requestWhenInUseAuthorizationIfNeeded()
        #expect(manager.authorizationRequestCount == 1)
    }

    @Test("Denied permission stops before requesting a fix")
    func deniedPermission() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .denied)
        let service = LocationService(preferences: fixture.preferences, manager: manager)

        await expectLocationError("location_permission_denied") {
            try await service.currentLocation()
        }
        #expect(manager.requestLocationCount == 0)
    }

    @Test("A second request is rejected while a fix is pending")
    func requestInProgress() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        let firstRequest = await startRequest(service: service, manager: manager)

        await expectLocationError("location_request_in_progress") {
            try await service.currentLocation()
        }

        firstRequest.cancel()
        await expectCancellation(firstRequest)
    }

    @Test("A request times out and releases the pending slot")
    func timeout() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            requestTimeout: .milliseconds(10)
        )

        await expectLocationError("location_timed_out") {
            try await service.currentLocation()
        }
        #expect(manager.requestLocationCount == 1)
    }

    @Test("Task cancellation cancels the one-shot request")
    func cancellation() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        let request = await startRequest(service: service, manager: manager)

        request.cancel()

        await expectCancellation(request)
    }

    @Test("Revoked consent rejects a fix that was already in flight")
    func consentRevocation() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        let request = await startRequest(service: service, manager: manager)

        fixture.preferences.locationEnabled = false
        manager.deliver([makeLocation(verticalAccuracy: 5)])

        await expectLocationError("location_sharing_disabled", from: request)
    }

    @Test("Invalid vertical accuracy omits altitude fields")
    func invalidAltitude() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        let request = await startRequest(service: service, manager: manager)

        manager.deliver([makeLocation(verticalAccuracy: -1)])
        let snapshot = try await request.value

        #expect(snapshot.altitudeMeters == nil)
        #expect(snapshot.ellipsoidalAltitudeMeters == nil)
        #expect(snapshot.verticalAccuracyMeters == nil)
    }

    @Test("Zero vertical accuracy remains a valid altitude measurement")
    func zeroAltitudeAccuracy() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        let request = await startRequest(service: service, manager: manager)

        manager.deliver([makeLocation(verticalAccuracy: 0)])
        let snapshot = try await request.value

        #expect(snapshot.altitudeMeters == 181)
        #expect(snapshot.ellipsoidalAltitudeMeters != nil)
        #expect(snapshot.verticalAccuracyMeters == 0)
    }

    @Test("Delegate failures release the request with a stable error")
    func delegateFailure() async throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager()
        let service = LocationService(preferences: fixture.preferences, manager: manager)
        let request = await startRequest(service: service, manager: manager)

        manager.fail(with: CLError(.locationUnknown))

        await expectLocationError("location_unavailable", from: request)
    }

    @Test("Background opt-in requests Always through a service session")
    func backgroundOptInUsesServiceSession() throws {
        let fixture = try PreferencesFixture(locationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let session = FakeAuthorizationSession()
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            significantLocationChangeMonitoringAvailable: true,
            authorizationSessionFactory: { session }
        )

        service.setBackgroundMonitoringEnabled(true)

        #expect(fixture.preferences.backgroundLocationEnabled)
        #expect(session.invalidateCount == 0)
        #expect(manager.startSignificantCount == 0)

        manager.changeAuthorization(to: .authorizedAlways)
        #expect(manager.startSignificantCount == 1)
        #expect(service.isBackgroundMonitoringActive)
    }

    @Test("An authorized relaunch restores significant-change monitoring")
    func restoresAuthorizedMonitoring() throws {
        let fixture = try PreferencesFixture(locationEnabled: true, backgroundLocationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let session = FakeAuthorizationSession()

        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            significantLocationChangeMonitoringAvailable: true,
            authorizationSessionFactory: { session }
        )

        #expect(manager.startSignificantCount == 1)
        #expect(service.isBackgroundMonitoringActive)
    }

    @Test("Significant changes publish without a pending foreground request")
    func significantChangeCallback() throws {
        let fixture = try PreferencesFixture(locationEnabled: true, backgroundLocationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            significantLocationChangeMonitoringAvailable: true,
            authorizationSessionFactory: { FakeAuthorizationSession() }
        )
        var snapshots: [LocationSnapshot] = []
        service.onSignificantLocation = { snapshots.append($0) }

        manager.deliver([makeLocation(verticalAccuracy: 5)])

        #expect(snapshots.count == 1)
        #expect(snapshots.first?.latitude == 41.88)
        #expect(manager.requestLocationCount == 0)
    }

    @Test("Disabling background sharing stops monitoring and invalidates the session")
    func backgroundDisableStopsMonitoring() throws {
        let fixture = try PreferencesFixture(locationEnabled: true, backgroundLocationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let session = FakeAuthorizationSession()
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            significantLocationChangeMonitoringAvailable: true,
            authorizationSessionFactory: { session }
        )

        service.setBackgroundMonitoringEnabled(false)

        #expect(fixture.preferences.backgroundLocationEnabled == false)
        #expect(manager.stopSignificantCount == 1)
        #expect(session.invalidateCount == 1)
        #expect(service.isBackgroundMonitoringActive == false)
    }

    @Test("Unsupported significant-change monitoring remains inactive")
    func unsupportedSignificantChangeMonitoring() throws {
        let fixture = try PreferencesFixture(locationEnabled: true, backgroundLocationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedAlways)
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            significantLocationChangeMonitoringAvailable: false,
            authorizationSessionFactory: { FakeAuthorizationSession() }
        )
        var unavailableCount = 0
        service.onBackgroundLocationUnavailable = { unavailableCount += 1 }

        service.restoreBackgroundMonitoringIfAuthorized()

        #expect(manager.startSignificantCount == 0)
        #expect(service.isBackgroundMonitoringActive == false)
        #expect(unavailableCount == 1)
    }

    @Test("A relaunch with insufficient permission emits one withdrawal hook")
    func insufficientPermissionWithdraws() throws {
        let fixture = try PreferencesFixture(locationEnabled: true, backgroundLocationEnabled: true)
        defer { fixture.cleanup() }
        let manager = FakeLocationManager(authorizationStatus: .authorizedWhenInUse)
        let service = LocationService(
            preferences: fixture.preferences,
            manager: manager,
            authorizationSessionFactory: { FakeAuthorizationSession() }
        )
        var withdrawalCount = 0
        service.onBackgroundLocationUnavailable = { withdrawalCount += 1 }

        service.restoreBackgroundMonitoringIfAuthorized()
        service.restoreBackgroundMonitoringIfAuthorized()

        #expect(withdrawalCount == 1)
        #expect(manager.startSignificantCount == 0)
    }
}

@MainActor
private final class FakeLocationManager: LocationManaging {
    weak var delegate: (any CLLocationManagerDelegate)?
    var desiredAccuracy: CLLocationAccuracy = kCLLocationAccuracyThreeKilometers
    var authorizationStatus: CLAuthorizationStatus
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    private(set) var authorizationRequestCount = 0
    private(set) var requestLocationCount = 0
    private(set) var startSignificantCount = 0
    private(set) var stopSignificantCount = 0

    private let callbackManager = CLLocationManager()

    init(authorizationStatus: CLAuthorizationStatus = .authorizedWhenInUse) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {
        authorizationRequestCount += 1
    }

    func requestLocation() {
        requestLocationCount += 1
    }

    func startMonitoringSignificantLocationChanges() {
        startSignificantCount += 1
    }

    func stopMonitoringSignificantLocationChanges() {
        stopSignificantCount += 1
    }

    func changeAuthorization(to status: CLAuthorizationStatus) {
        authorizationStatus = status
        delegate?.locationManagerDidChangeAuthorization?(callbackManager)
    }

    func deliver(_ locations: [CLLocation]) {
        delegate?.locationManager?(callbackManager, didUpdateLocations: locations)
    }

    func fail(with error: Error) {
        delegate?.locationManager?(callbackManager, didFailWithError: error)
    }
}

@MainActor
private final class FakeAuthorizationSession: LocationAuthorizationSession {
    private(set) var invalidateCount = 0

    func invalidate() {
        invalidateCount += 1
    }
}

@MainActor
private final class PreferencesFixture {
    let preferences: SharingPreferences
    private let defaults: UserDefaults
    private let suite: String

    init(locationEnabled: Bool = false, backgroundLocationEnabled: Bool = false) throws {
        suite = "LocationServiceTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = SharingPreferences(defaults: defaults)
        preferences.locationEnabled = locationEnabled
        preferences.backgroundLocationEnabled = backgroundLocationEnabled
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

@MainActor
private func startRequest(
    service: LocationService,
    manager: FakeLocationManager
) async -> Task<LocationSnapshot, Error> {
    let request = Task { try await service.currentLocation() }
    for _ in 0..<100 {
        if manager.requestLocationCount > 0 {
            return request
        }
        await Task.yield()
    }
    Issue.record("Location request did not start")
    return request
}

@MainActor
private func expectLocationError(
    _ expectedCode: String,
    operation: () async throws -> LocationSnapshot
) async {
    do {
        _ = try await operation()
        Issue.record("Expected location error \(expectedCode)")
    } catch let error as LocationServiceError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}

@MainActor
private func expectLocationError(
    _ expectedCode: String,
    from task: Task<LocationSnapshot, Error>
) async {
    await expectLocationError(expectedCode) {
        try await task.value
    }
}

@MainActor
private func expectCancellation(_ task: Task<LocationSnapshot, Error>) async {
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch is CancellationError {
        return
    } catch {
        Issue.record("Unexpected cancellation error: \(error)")
    }
}

private func makeLocation(verticalAccuracy: CLLocationAccuracy) -> CLLocation {
    CLLocation(
        coordinate: CLLocationCoordinate2D(latitude: 41.88, longitude: -87.63),
        altitude: 181,
        horizontalAccuracy: 5,
        verticalAccuracy: verticalAccuracy,
        course: 90,
        speed: 4,
        timestamp: Date(timeIntervalSince1970: 1_788_000_000)
    )
}
