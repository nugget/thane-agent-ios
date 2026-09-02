import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Photo service")
@MainActor
struct PhotoServiceTests {
    @Test("Default-off access never reads or prompts for Photos")
    func defaultOff() async throws {
        let fixture = try PhotoPreferencesFixture()
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(authorizationStatus: .full)
        let service = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        )

        await expectPhotoError("photos_sharing_disabled") {
            try await service.recentPhotos()
        }
        #expect(library.authorizationRequestCount == 0)
        #expect(library.fetchCount == 0)
    }

    @Test("Remote reads cannot originate the Photos permission prompt")
    func permissionPromptGate() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(
            authorizationStatus: .notDetermined,
            requestedAuthorization: .full
        )
        let service = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        )

        await expectPhotoError("photos_permission_not_requested") {
            try await service.recentPhotos()
        }
        #expect(library.authorizationRequestCount == 0)
        #expect(library.fetchCount == 0)

        #expect(await service.requestAuthorizationFromOperatorAction() == .full)
        #expect(library.authorizationRequestCount == 1)
        _ = try await service.recentPhotos()
        #expect(library.fetchCount == 1)
    }

    @Test("Recent results are bounded, explicit, and contain no raw PhotoKit identifier")
    func boundedMetadata() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(
            authorizationStatus: .full,
            assets: [
                makePhotoAsset(id: "raw-local-id-1", timestamp: 300),
                makePhotoAsset(id: "raw-local-id-2", timestamp: 200),
                makePhotoAsset(id: "raw-local-id-3", timestamp: 100),
            ]
        )
        let service = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        )

        let snapshot = try await service.recentPhotos(
            limit: 2,
            includeEmbeddedMetadata: true,
            at: Date(timeIntervalSince1970: 400)
        )

        #expect(library.lastLimit == 3)
        #expect(library.lastIncludedEmbeddedMetadata == true)
        #expect(snapshot.authorization == .full)
        #expect(snapshot.hiddenAssetsExcluded)
        #expect(snapshot.iCloudDownloadsAllowed == false)
        #expect(snapshot.requestedLimit == 2)
        #expect(snapshot.returnedCount == 2)
        #expect(snapshot.truncated)
        #expect(snapshot.photos.map(\.createdAt) == [
            "1970-01-01T00:05:00.000Z",
            "1970-01-01T00:03:20.000Z",
        ])
        #expect(snapshot.photos.allSatisfy { $0.assetID.hasPrefix("photo_") })
        #expect(snapshot.photos.allSatisfy { !$0.assetID.contains("raw-local-id") })

        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("raw-local-id"))
        #expect(!json.contains("pixel_data"))
    }

    @Test("Asset identifiers are stable per connection and unlinkable across connections")
    func pairwiseAssetIdentifiers() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(
            authorizationStatus: .full,
            assets: [makePhotoAsset(id: "same-library-asset", timestamp: 100)]
        )
        let first = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        )
        let second = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-two" }
        )

        let firstID = try #require(await first.recentPhotos().photos.first?.assetID)
        let repeatedID = try #require(await first.recentPhotos().photos.first?.assetID)
        let secondID = try #require(await second.recentPhotos().photos.first?.assetID)

        #expect(firstID == repeatedID)
        #expect(firstID != secondID)
    }

    @Test("Limited-library access stays visible in the result contract")
    func limitedLibraryScope() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let service = PhotoService(
            preferences: fixture.preferences,
            library: FakePhotoLibrary(authorizationStatus: .limited),
            identifierNamespace: { "pairwise-one" }
        )

        let snapshot = try await service.recentPhotos()

        #expect(snapshot.authorization == .limited)
    }

    @Test("Invalid limits are rejected before Photos is read")
    func invalidLimits() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(authorizationStatus: .full)
        let service = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        )

        await expectPhotoError("invalid_request") {
            try await service.recentPhotos(limit: 0)
        }
        await expectPhotoError("invalid_request") {
            try await service.recentPhotos(limit: PhotoService.maximumPhotoCount + 1)
        }
        #expect(library.fetchCount == 0)
    }

    @Test("The companion-authored tool schema and parameters stay aligned")
    func toolContract() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(
            authorizationStatus: .full,
            assets: [makePhotoAsset(id: "asset", timestamp: 100)]
        )
        let handler = PhotoPlatformHandler(service: PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        ))

        #expect(handler.supportedMethods == ["list_recent"])
        let tool = try #require(handler.toolDefinitions.first)
        #expect(tool.name == "ios_recent_photos")
        #expect(tool.method == "list_recent")
        #expect(tool.inputSchema["additionalProperties"]?.value as? Bool == false)

        let result = try await handler.handle(
            method: "list_recent",
            params: [
                "limit": AnyCodable(1),
                "include_embedded_metadata": AnyCodable(false),
            ]
        )
        let object = try #require(result.value as? [String: Any])

        #expect(library.lastLimit == 2)
        #expect(library.lastIncludedEmbeddedMetadata == false)
        #expect(object["returned_count"] as? Int64 == 1)
        #expect(object["icloud_downloads_allowed"] as? Bool == false)
        let photos = try #require(object["photos"] as? [[String: Any]])
        #expect(photos.first?["embedded_metadata"] == nil)
        #expect(photos.first?["embedded_metadata_status"] as? String == "not_requested")

        do {
            _ = try await handler.handle(
                method: "list_recent",
                params: ["unexpected": AnyCodable(true)]
            )
            Issue.record("Expected unsupported Photos parameters to fail")
        } catch let error as PhotoServiceError {
            #expect(error.code == "invalid_request")
        }
    }
}

@MainActor
private final class FakePhotoLibrary: PhotoLibraryReading {
    var authorizationStatus: PhotoAuthorizationState
    var requestedAuthorization: PhotoAuthorizationState
    var assets: [PhotoLibraryAsset]
    private(set) var authorizationRequestCount = 0
    private(set) var fetchCount = 0
    private(set) var lastLimit: Int?
    private(set) var lastIncludedEmbeddedMetadata: Bool?

    init(
        authorizationStatus: PhotoAuthorizationState,
        requestedAuthorization: PhotoAuthorizationState? = nil,
        assets: [PhotoLibraryAsset] = []
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestedAuthorization = requestedAuthorization ?? authorizationStatus
        self.assets = assets
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        authorizationRequestCount += 1
        authorizationStatus = requestedAuthorization
        return authorizationStatus
    }

    func fetchRecentPhotos(
        limit: Int,
        includeEmbeddedMetadata: Bool
    ) async throws -> [PhotoLibraryAsset] {
        fetchCount += 1
        lastLimit = limit
        lastIncludedEmbeddedMetadata = includeEmbeddedMetadata
        return Array(assets.prefix(limit))
    }
}

@MainActor
private final class PhotoPreferencesFixture {
    let preferences: SharingPreferences
    private let defaults: UserDefaults
    private let suite: String

    init(photosEnabled: Bool = false) throws {
        suite = "PhotoServiceTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = SharingPreferences(defaults: defaults)
        preferences.scope(to: "thane:one")
        preferences.photosEnabled = photosEnabled
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
    }
}

private func makePhotoAsset(id: String, timestamp: TimeInterval) -> PhotoLibraryAsset {
    PhotoLibraryAsset(
        localIdentifier: id,
        creationDate: Date(timeIntervalSince1970: timestamp),
        modificationDate: Date(timeIntervalSince1970: timestamp + 10),
        pixelWidth: 4_032,
        pixelHeight: 3_024,
        isFavorite: true,
        mediaSubtypes: ["live_photo"],
        sourceTypes: ["user_library"],
        uniformTypeIdentifier: "public.heic",
        location: PhotoLocationMetadata(
            latitude: 41.88,
            longitude: -87.63,
            altitudeMeters: 181,
            horizontalAccuracyMeters: 5,
            verticalAccuracyMeters: 8
        ),
        embeddedMetadataStatus: .available,
        embeddedMetadata: PhotoEmbeddedMetadata(
            orientation: 1,
            cameraMake: "Apple",
            cameraModel: "iPhone",
            lensMake: "Apple",
            lensModel: "Back Camera",
            exposureTimeSeconds: 0.01,
            fNumber: 1.8,
            isoSpeedRatings: [80],
            focalLengthMillimeters: 6.8,
            exposureBiasEV: 0
        )
    )
}

@MainActor
private func expectPhotoError(
    _ expectedCode: String,
    operation: () async throws -> RecentPhotosSnapshot
) async {
    do {
        _ = try await operation()
        Issue.record("Expected photo error \(expectedCode)")
    } catch let error as PhotoServiceError {
        #expect(error.code == expectedCode)
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
