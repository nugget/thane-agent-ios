import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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
        #expect(library.lastEmbeddedMetadataLimit == 2)
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

    @Test("Consent revocation invalidates an in-flight metadata request")
    func consentRevocationInvalidatesInFlightRequest() async throws {
        let fixture = try PhotoPreferencesFixture(photosEnabled: true)
        defer { fixture.cleanup() }
        let library = FakePhotoLibrary(
            authorizationStatus: .full,
            assets: [makePhotoAsset(id: "asset", timestamp: 100)],
            suspendsFetch: true
        )
        let service = PhotoService(
            preferences: fixture.preferences,
            library: library,
            identifierNamespace: { "pairwise-one" }
        )
        let request = Task { @MainActor in
            try await service.recentPhotos()
        }
        try await waitForPhotoCondition { library.hasPendingFetch }

        fixture.preferences.photosEnabled = false
        service.cancelPendingRequestAfterConsentRevocation()
        fixture.preferences.photosEnabled = true
        library.resumeFetch()

        do {
            _ = try await request.value
            Issue.record("Expected revoked in-flight Photos request to fail")
        } catch let error as PhotoServiceError {
            #expect(error.code == "photos_sharing_disabled")
        }
    }

    @Test("Non-finite embedded values are omitted from transport metadata")
    func nonFiniteMetadata() throws {
        let metadata = PhotoEmbeddedMetadata(
            orientation: 1,
            cameraMake: "Apple",
            cameraModel: "iPhone",
            lensMake: nil,
            lensModel: nil,
            exposureTimeSeconds: .nan,
            fNumber: .infinity,
            isoSpeedRatings: [80],
            focalLengthMillimeters: -.infinity,
            exposureBiasEV: 0
        )

        #expect(metadata.exposureTimeSeconds == nil)
        #expect(metadata.fNumber == nil)
        #expect(metadata.focalLengthMillimeters == nil)
        #expect(metadata.exposureBiasEV == 0)
        _ = try JSONEncoder().encode(metadata)
    }

    @Test("Embedded metadata streaming cancels as soon as ImageIO can read the header")
    func embeddedMetadataCancelsEarly() async throws {
        let image = try makeMetadataJPEG()
        let (metadataPrefix, trailingData) = try metadataPrefixAndTrailing(from: image)
        let stream = ManuallyDrivenPhotoResourceStream()

        let request = PhotoEmbeddedMetadataResourceRequest(
            timeoutNanoseconds: 1_000_000_000
        )
        let resultTask = Task { await request.read(from: stream) }
        await stream.waitUntilStarted()

        stream.send(metadataPrefix)
        let result = await resultTask.value
        stream.send(trailingData)

        #expect(result.status == .available)
        #expect(result.metadata?.cameraMake == "Camera Maker")
        #expect(result.metadata?.cameraModel == "Camera Model")
        #expect(result.metadata?.isoSpeedRatings == [125])
        #expect(stream.cancellationCount == 1)
        #expect(stream.deliveredChunkCount == 1)
        #expect(stream.deliveredByteCount == metadataPrefix.count)
        #expect(stream.deliveredByteCount < image.count)
    }

    @Test("Oversized resource chunks parse the permitted prefix before cancellation")
    func oversizedMetadataChunk() async throws {
        let image = try makeMetadataJPEG()
        let (metadataPrefix, _) = try metadataPrefixAndTrailing(from: image)
        let stream = FakePhotoResourceStream(actions: [
            .data(image),
        ])
        let request = PhotoEmbeddedMetadataResourceRequest(
            maximumByteCount: metadataPrefix.count,
            timeoutNanoseconds: 1_000_000_000
        )

        let result = await request.read(from: stream)

        #expect(result.status == .available)
        #expect(result.metadata?.cameraMake == "Camera Maker")
        #expect(result.metadata?.cameraModel == "Camera Model")
        #expect(result.metadata?.isoSpeedRatings == [125])
        #expect(stream.cancellationCount == 1)
    }

    @Test("Embedded metadata streaming cancels exactly at its byte boundary")
    func embeddedMetadataByteLimit() async {
        let stream = FakePhotoResourceStream(actions: [
            .data(Data(repeating: 0, count: 32)),
        ])
        let request = PhotoEmbeddedMetadataResourceRequest(
            maximumByteCount: 32,
            timeoutNanoseconds: 1_000_000_000
        )

        let result = await request.read(from: stream)

        #expect(result.status == .unavailable)
        #expect(result.metadata == nil)
        #expect(stream.cancellationCount == 1)
    }

    @Test("Basic partial properties do not masquerade as complete embedded metadata")
    func partialBasicPropertiesDoNotCompleteEarly() async throws {
        let image = try makePlainJPEG()
        let (prefix, trailingData) = try basicPropertiesPrefixAndTrailing(from: image)
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, prefix as CFData, false)
        let partialProperties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?
        )
        #expect(partialProperties[kCGImagePropertyPixelWidth as String] != nil)
        let partialEXIF = partialProperties[kCGImagePropertyExifDictionary as String]
            as? NSDictionary
        let partialTIFF = partialProperties[kCGImagePropertyTIFFDictionary as String]
            as? NSDictionary
        #expect((partialEXIF?.count ?? 0) == 0 || (partialTIFF?.count ?? 0) == 0)

        let parser = IncrementalPhotoMetadataParser()
        #expect(parser.consume(prefix, isFinal: false) == nil)
        let metadata = try #require(parser.consume(trailingData, isFinal: true))

        #expect(metadata.cameraMake == nil)
        #expect(metadata.cameraModel == nil)
    }

    @Test("Caller cancellation stops the active metadata resource stream")
    func embeddedMetadataCallerCancellation() async {
        let stream = ManuallyDrivenPhotoResourceStream()
        let request = PhotoEmbeddedMetadataResourceRequest(
            timeoutNanoseconds: 1_000_000_000
        )
        let resultTask = Task { await request.read(from: stream) }
        await stream.waitUntilStarted()

        resultTask.cancel()
        let result = await resultTask.value

        #expect(result.status == .unavailable)
        #expect(result.metadata == nil)
        #expect(stream.cancellationCount == 1)
    }

    @Test("Embedded metadata streaming cancels stalled local reads")
    func embeddedMetadataTimeout() async {
        let stream = FakePhotoResourceStream()
        let request = PhotoEmbeddedMetadataResourceRequest(
            maximumByteCount: 32,
            timeoutNanoseconds: 5_000_000
        )

        let result = await request.read(from: stream)

        #expect(result.status == .unavailable)
        #expect(stream.cancellationCount == 1)
    }

    @Test("Embedded metadata distinguishes iCloud-only resources without downloading")
    func embeddedMetadataNotLocal() async {
        let stream = FakePhotoResourceStream(actions: [
            .completion(.networkAccessRequired),
        ])

        let result = await PhotoEmbeddedMetadataResourceRequest().read(from: stream)

        #expect(result.status == .notLocal)
        #expect(result.metadata == nil)
        #expect(stream.cancellationCount == 0)
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
        #expect(library.lastEmbeddedMetadataLimit == 0)
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

private nonisolated final class FakePhotoResourceStream:
    PhotoResourceStreaming,
    @unchecked Sendable
{
    enum Action: Sendable {
        case data(Data)
        case completion(PhotoResourceCompletion)
    }

    private let actions: [Action]
    private let lock = NSLock()
    private var storedCancellationCount = 0

    var cancellationCount: Int {
        lock.withLock { storedCancellationCount }
    }

    init(actions: [Action] = []) {
        self.actions = actions
    }

    func start(
        dataReceived: @escaping @Sendable (Data) -> Void,
        completion: @escaping @Sendable (PhotoResourceCompletion) -> Void
    ) -> @Sendable () -> Void {
        for action in actions {
            switch action {
            case .data(let data):
                dataReceived(data)
            case .completion(let result):
                completion(result)
            }
        }
        return { [weak self] in
            self?.lock.withLock {
                self?.storedCancellationCount += 1
            }
        }
    }
}

private nonisolated final class ManuallyDrivenPhotoResourceStream:
    PhotoResourceStreaming,
    @unchecked Sendable
{
    private struct State {
        var dataReceived: (@Sendable (Data) -> Void)?
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var isStarted = false
        var isCancelled = false
        var cancellationCount = 0
        var deliveredChunkCount = 0
        var deliveredByteCount = 0
    }

    private let lock = NSLock()
    private var state = State()

    var cancellationCount: Int {
        lock.withLock { state.cancellationCount }
    }

    var deliveredChunkCount: Int {
        lock.withLock { state.deliveredChunkCount }
    }

    var deliveredByteCount: Int {
        lock.withLock { state.deliveredByteCount }
    }

    func start(
        dataReceived: @escaping @Sendable (Data) -> Void,
        completion _: @escaping @Sendable (PhotoResourceCompletion) -> Void
    ) -> @Sendable () -> Void {
        let waiters = lock.withLock {
            state.dataReceived = dataReceived
            state.isStarted = true
            let waiters = state.startWaiters
            state.startWaiters.removeAll()
            return waiters
        }
        waiters.forEach { $0.resume() }
        return { [weak self] in
            self?.cancel()
        }
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !state.isStarted else { return true }
                state.startWaiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func send(_ data: Data) {
        let dataReceived = lock.withLock { () -> (@Sendable (Data) -> Void)? in
            guard !state.isCancelled else { return nil }
            state.deliveredChunkCount += 1
            state.deliveredByteCount += data.count
            return state.dataReceived
        }
        dataReceived?(data)
    }

    private func cancel() {
        lock.withLock {
            guard !state.isCancelled else { return }
            state.isCancelled = true
            state.cancellationCount += 1
            state.dataReceived = nil
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
    private(set) var lastEmbeddedMetadataLimit: Int?
    private(set) var hasPendingFetch = false
    private var fetchContinuation: CheckedContinuation<[PhotoLibraryAsset], Error>?
    private let suspendsFetch: Bool

    init(
        authorizationStatus: PhotoAuthorizationState,
        requestedAuthorization: PhotoAuthorizationState? = nil,
        assets: [PhotoLibraryAsset] = [],
        suspendsFetch: Bool = false
    ) {
        self.authorizationStatus = authorizationStatus
        self.requestedAuthorization = requestedAuthorization ?? authorizationStatus
        self.assets = assets
        self.suspendsFetch = suspendsFetch
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        authorizationRequestCount += 1
        authorizationStatus = requestedAuthorization
        return authorizationStatus
    }

    func fetchRecentPhotos(
        limit: Int,
        embeddedMetadataLimit: Int
    ) async throws -> [PhotoLibraryAsset] {
        fetchCount += 1
        lastLimit = limit
        lastEmbeddedMetadataLimit = embeddedMetadataLimit
        if suspendsFetch {
            hasPendingFetch = true
            return try await withCheckedThrowingContinuation { continuation in
                fetchContinuation = continuation
            }
        }
        return Array(assets.prefix(limit))
    }

    func resumeFetch() {
        hasPendingFetch = false
        let continuation = fetchContinuation
        fetchContinuation = nil
        continuation?.resume(returning: Array(assets.prefix(lastLimit ?? 0)))
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

private func makeMetadataJPEG() throws -> Data {
    try makeTestImage(
        type: .jpeg,
        properties: [
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Camera Maker",
                kCGImagePropertyTIFFModel: "Camera Model",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifLensMake: "Lens Maker",
                kCGImagePropertyExifLensModel: "Lens Model",
                kCGImagePropertyExifExposureTime: 0.01,
                kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifISOSpeedRatings: [125],
                kCGImagePropertyExifFocalLength: 6.8,
                kCGImagePropertyExifExposureBiasValue: 0,
            ],
        ]
    )
}

private func makePlainJPEG() throws -> Data {
    try makeTestImage(type: .jpeg, properties: [:])
}

private func makeTestImage(type: UTType, properties: NSDictionary) throws -> Data {
    let pixelData = Data([255, 0, 0, 255])
    let provider = try #require(CGDataProvider(data: pixelData as CFData))
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )
    let image = try #require(CGImage(
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ))
    let output = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        output,
        type.identifier as CFString,
        1,
        nil
    ))
    CGImageDestinationAddImage(destination, image, properties)
    try #require(CGImageDestinationFinalize(destination))
    return output as Data
}

private func metadataPrefixAndTrailing(from image: Data) throws -> (Data, Data) {
    let step = 32
    for end in stride(from: step, to: image.count, by: step) {
        let prefix = Data(image.prefix(end))
        guard let source = CGImageSourceCreateWithData(prefix as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary?,
              let tiff = properties[kCGImagePropertyTIFFDictionary as String]
                as? NSDictionary,
              tiff[kCGImagePropertyTIFFMake as String] as? String == "Camera Maker" else {
            continue
        }
        return (prefix, Data(image.dropFirst(end)))
    }
    Issue.record("The JPEG fixture did not expose metadata before its trailing image data")
    throw MetadataFixtureError.noParseablePrefix
}

private func basicPropertiesPrefixAndTrailing(from image: Data) throws -> (Data, Data) {
    for end in 1..<image.count {
        let prefix = Data(image.prefix(end))
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, prefix as CFData, false)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary?,
              properties[kCGImagePropertyPixelWidth as String] != nil else {
            continue
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? NSDictionary
        guard (exif?.count ?? 0) == 0 || (tiff?.count ?? 0) == 0 else { continue }
        return (prefix, Data(image.dropFirst(end)))
    }
    Issue.record("The image fixture did not expose basic properties before its image data")
    throw MetadataFixtureError.noParseablePrefix
}

private enum MetadataFixtureError: Error {
    case noParseablePrefix
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

@MainActor
private func waitForPhotoCondition(
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    for _ in 0..<100 where !condition() {
        try await Task.sleep(for: .milliseconds(1))
    }
    try #require(condition())
}
