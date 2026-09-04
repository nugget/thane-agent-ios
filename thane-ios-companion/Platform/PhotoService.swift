import CryptoKit
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers

nonisolated enum PhotoAuthorizationState: String, Codable, Equatable, Sendable {
    case notDetermined = "not_determined"
    case restricted
    case denied
    case limited
    case full

    var permitsRead: Bool {
        self == .limited || self == .full
    }
}

nonisolated enum PhotoEmbeddedMetadataStatus: String, Codable, Equatable, Sendable {
    case notRequested = "not_requested"
    case available
    case notLocal = "not_local"
    case unavailable
}

nonisolated struct PhotoLocationMetadata: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
    let horizontalAccuracyMeters: Double?
    let verticalAccuracyMeters: Double?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case altitudeMeters = "altitude_meters"
        case horizontalAccuracyMeters = "horizontal_accuracy_meters"
        case verticalAccuracyMeters = "vertical_accuracy_meters"
    }
}

nonisolated struct PhotoEmbeddedMetadata: Codable, Equatable, Sendable {
    let orientation: Int?
    let cameraMake: String?
    let cameraModel: String?
    let lensMake: String?
    let lensModel: String?
    let exposureTimeSeconds: Double?
    let fNumber: Double?
    let isoSpeedRatings: [Int]?
    let focalLengthMillimeters: Double?
    let exposureBiasEV: Double?

    init(
        orientation: Int?,
        cameraMake: String?,
        cameraModel: String?,
        lensMake: String?,
        lensModel: String?,
        exposureTimeSeconds: Double?,
        fNumber: Double?,
        isoSpeedRatings: [Int]?,
        focalLengthMillimeters: Double?,
        exposureBiasEV: Double?
    ) {
        self.orientation = orientation
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensMake = lensMake
        self.lensModel = lensModel
        self.exposureTimeSeconds = Self.finite(exposureTimeSeconds)
        self.fNumber = Self.finite(fNumber)
        self.isoSpeedRatings = isoSpeedRatings
        self.focalLengthMillimeters = Self.finite(focalLengthMillimeters)
        self.exposureBiasEV = Self.finite(exposureBiasEV)
    }

    enum CodingKeys: String, CodingKey {
        case orientation
        case cameraMake = "camera_make"
        case cameraModel = "camera_model"
        case lensMake = "lens_make"
        case lensModel = "lens_model"
        case exposureTimeSeconds = "exposure_time_seconds"
        case fNumber = "f_number"
        case isoSpeedRatings = "iso_speed_ratings"
        case focalLengthMillimeters = "focal_length_millimeters"
        case exposureBiasEV = "exposure_bias_ev"
    }

    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }
}

nonisolated struct RecentPhotoMetadata: Codable, Equatable, Sendable {
    let assetID: String
    let createdAt: String?
    let modifiedAt: String?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let mediaSubtypes: [String]
    let sourceTypes: [String]
    let uniformTypeIdentifier: String?
    let location: PhotoLocationMetadata?
    let embeddedMetadataStatus: PhotoEmbeddedMetadataStatus
    let embeddedMetadata: PhotoEmbeddedMetadata?

    enum CodingKeys: String, CodingKey {
        case assetID = "asset_id"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case isFavorite = "is_favorite"
        case mediaSubtypes = "media_subtypes"
        case sourceTypes = "source_types"
        case uniformTypeIdentifier = "uniform_type_identifier"
        case location
        case embeddedMetadataStatus = "embedded_metadata_status"
        case embeddedMetadata = "embedded_metadata"
    }
}

nonisolated struct RecentPhotosSnapshot: Codable, Equatable, Sendable {
    let capturedAt: String
    let authorization: PhotoAuthorizationState
    let hiddenAssetsExcluded: Bool
    let iCloudDownloadsAllowed: Bool
    let requestedLimit: Int
    let returnedCount: Int
    let truncated: Bool
    let photos: [RecentPhotoMetadata]

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case authorization
        case hiddenAssetsExcluded = "hidden_assets_excluded"
        case iCloudDownloadsAllowed = "icloud_downloads_allowed"
        case requestedLimit = "requested_limit"
        case returnedCount = "returned_count"
        case truncated
        case photos
    }
}

nonisolated enum PhotoServiceError: PlatformServiceError, Equatable, Sendable {
    case sharingDisabled
    case permissionNotRequested
    case permissionDenied
    case permissionRestricted
    case invalidRequest(String)
    case identityUnavailable
    case libraryUnavailable(String)
    case unsupportedMethod(String)

    var code: String {
        switch self {
        case .sharingDisabled: "photos_sharing_disabled"
        case .permissionNotRequested: "photos_permission_not_requested"
        case .permissionDenied: "photos_permission_denied"
        case .permissionRestricted: "photos_permission_restricted"
        case .invalidRequest: "invalid_request"
        case .identityUnavailable: "photos_identity_unavailable"
        case .libraryUnavailable: "photos_unavailable"
        case .unsupportedMethod: "unknown_method"
        }
    }

    var errorDescription: String? {
        switch self {
        case .sharingDisabled:
            "Recent Photo Metadata sharing is disabled in the iOS companion app."
        case .permissionNotRequested:
            "Enable Recent Photo Metadata in the iOS companion before requesting photos."
        case .permissionDenied:
            "Photos permission is denied. It can be changed in iOS Settings."
        case .permissionRestricted:
            "Photos access is restricted on this device."
        case .invalidRequest(let message):
            "Invalid Photos request: \(message)"
        case .identityUnavailable:
            "A pairwise companion identity is required before photo metadata can be shared."
        case .libraryUnavailable(let message):
            "Photo metadata is unavailable: \(message)"
        case .unsupportedMethod(let method):
            "Unsupported Photos method: \(method)"
        }
    }
}

nonisolated struct PhotoLibraryAsset: Equatable, Sendable {
    let localIdentifier: String
    let creationDate: Date?
    let modificationDate: Date?
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let mediaSubtypes: [String]
    let sourceTypes: [String]
    let uniformTypeIdentifier: String?
    let location: PhotoLocationMetadata?
    let embeddedMetadataStatus: PhotoEmbeddedMetadataStatus
    let embeddedMetadata: PhotoEmbeddedMetadata?
}

@MainActor
protocol PhotoLibraryReading: AnyObject {
    var authorizationStatus: PhotoAuthorizationState { get }

    func requestAuthorization() async -> PhotoAuthorizationState
    func fetchRecentPhotos(
        limit: Int,
        embeddedMetadataLimit: Int
    ) async throws -> [PhotoLibraryAsset]
}

@MainActor
final class SystemPhotoLibraryReader: PhotoLibraryReading {
    var authorizationStatus: PhotoAuthorizationState {
        Self.authorizationState(
            PHPhotoLibrary.authorizationStatus(for: .readWrite)
        )
    }

    func requestAuthorization() async -> PhotoAuthorizationState {
        Self.authorizationState(
            await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        )
    }

    func fetchRecentPhotos(
        limit: Int,
        embeddedMetadataLimit: Int
    ) async throws -> [PhotoLibraryAsset] {
        let options = PHFetchOptions()
        options.fetchLimit = limit
        options.includeHiddenAssets = false
        options.includeAllBurstAssets = false
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
        ]

        let result = PHAsset.fetchAssets(with: .image, options: options)
        var photos: [PhotoLibraryAsset] = []
        photos.reserveCapacity(result.count)

        for index in 0..<result.count {
            let asset = result.object(at: index)
            let embedded: PhotoEmbeddedMetadataResult
            if index < embeddedMetadataLimit {
                embedded = await Self.embeddedMetadata(for: asset)
            } else {
                embedded = PhotoEmbeddedMetadataResult(
                    status: .notRequested,
                    metadata: nil
                )
            }
            photos.append(PhotoLibraryAsset(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                mediaSubtypes: Self.mediaSubtypeLabels(asset.mediaSubtypes),
                sourceTypes: Self.sourceTypeLabels(asset.sourceType),
                uniformTypeIdentifier: Self.bounded(asset.contentType.identifier),
                location: Self.locationMetadata(asset.location),
                embeddedMetadataStatus: embedded.status,
                embeddedMetadata: embedded.metadata
            ))
        }
        return photos
    }

    @concurrent
    private static func embeddedMetadata(
        for asset: PHAsset
    ) async -> PhotoEmbeddedMetadataResult {
        guard let resource = preferredResource(for: asset) else {
            return PhotoEmbeddedMetadataResult(status: .unavailable, metadata: nil)
        }
        return await PhotoEmbeddedMetadataResourceRequest().read(
            from: SystemPhotoResourceStream(resource: resource)
        )
    }

    private nonisolated static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .photo }
            ?? resources.first { $0.type == .fullSizePhoto }
            ?? resources.first
    }

    private nonisolated static func locationMetadata(
        _ location: CLLocation?
    ) -> PhotoLocationMetadata? {
        guard let location else { return nil }
        return PhotoLocationMetadata(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitudeMeters: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracyMeters: location.horizontalAccuracy >= 0
                ? location.horizontalAccuracy
                : nil,
            verticalAccuracyMeters: location.verticalAccuracy >= 0
                ? location.verticalAccuracy
                : nil
        )
    }

    private nonisolated static func mediaSubtypeLabels(
        _ subtypes: PHAssetMediaSubtype
    ) -> [String] {
        let candidates: [(PHAssetMediaSubtype, String)] = [
            (.photoPanorama, "panorama"),
            (.photoHDR, "hdr"),
            (.photoScreenshot, "screenshot"),
            (.photoLive, "live_photo"),
            (.photoDepthEffect, "depth_effect"),
            (.spatialMedia, "spatial_media"),
        ]
        return candidates.compactMap { subtype, label in
            subtypes.contains(subtype) ? label : nil
        }
    }

    private nonisolated static func sourceTypeLabels(
        _ sourceTypes: PHAssetSourceType
    ) -> [String] {
        let candidates: [(PHAssetSourceType, String)] = [
            (.typeUserLibrary, "user_library"),
            (.typeCloudShared, "cloud_shared"),
            (.typeiTunesSynced, "itunes_synced"),
        ]
        return candidates.compactMap { sourceType, label in
            sourceTypes.contains(sourceType) ? label : nil
        }
    }

    private nonisolated static func authorizationState(
        _ status: PHAuthorizationStatus
    ) -> PhotoAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .limited: .limited
        case .authorized: .full
        @unknown default: .denied
        }
    }

    private nonisolated static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        var end = value.startIndex
        var byteCount = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextByteCount = value[end..<next].utf8.count
            guard byteCount + nextByteCount <= 128 else { break }
            byteCount += nextByteCount
            end = next
        }
        return String(value[..<end])
    }
}

nonisolated struct PhotoEmbeddedMetadataResult: Sendable {
    let status: PhotoEmbeddedMetadataStatus
    let metadata: PhotoEmbeddedMetadata?
}

nonisolated enum PhotoResourceCompletion: Sendable {
    case success
    case networkAccessRequired
    case failure
}

nonisolated protocol PhotoResourceStreaming: Sendable {
    func start(
        dataReceived: @escaping @Sendable (Data) -> Void,
        completion: @escaping @Sendable (PhotoResourceCompletion) -> Void
    ) -> @Sendable () -> Void
}

nonisolated struct SystemPhotoResourceStream: PhotoResourceStreaming, @unchecked Sendable {
    let resource: PHAssetResource
    let manager: PHAssetResourceManager

    init(
        resource: PHAssetResource,
        manager: PHAssetResourceManager = .default()
    ) {
        self.resource = resource
        self.manager = manager
    }

    func start(
        dataReceived: @escaping @Sendable (Data) -> Void,
        completion: @escaping @Sendable (PhotoResourceCompletion) -> Void
    ) -> @Sendable () -> Void {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let requestID = manager.requestData(
            for: resource,
            options: options,
            dataReceivedHandler: dataReceived
        ) { error in
            completion(Self.completion(for: error))
        }
        return { manager.cancelDataRequest(requestID) }
    }

    private static func completion(for error: Error?) -> PhotoResourceCompletion {
        guard let error else { return .success }
        let nsError = error as NSError
        if nsError.domain == PHPhotosErrorDomain,
           nsError.code == PHPhotosError.networkAccessRequired.rawValue {
            return .networkAccessRequired
        }
        return .failure
    }
}

nonisolated final class PhotoEmbeddedMetadataResourceRequest: @unchecked Sendable {
    static let maximumByteCount = 1_048_576
    static let timeoutNanoseconds: UInt64 = 1_000_000_000

    private struct State {
        var continuation: CheckedContinuation<PhotoEmbeddedMetadataResult, Never>?
        var result: PhotoEmbeddedMetadataResult?
        var cancellation: (@Sendable () -> Void)?
        var cancelWhenAvailable = false
        var timeoutTask: Task<Void, Never>?
    }

    private let maximumByteCount: Int
    private let timeoutNanoseconds: UInt64
    private let processingQueue = DispatchQueue(
        label: "info.nugget.thane-ios-companion.photo-metadata",
        qos: .utility
    )
    private let lock = NSLock()
    private let parser = IncrementalPhotoMetadataParser()
    private var receivedByteCount = 0
    private var state = State()

    init(
        maximumByteCount: Int = maximumByteCount,
        timeoutNanoseconds: UInt64 = timeoutNanoseconds
    ) {
        self.maximumByteCount = maximumByteCount
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func read(from stream: any PhotoResourceStreaming) async -> PhotoEmbeddedMetadataResult {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard install(continuation: continuation) else { return }
                if Task.isCancelled {
                    finish(unavailableResult, cancellingRequest: true)
                    return
                }

                let cancellation = stream.start { [weak self] data in
                    guard let self else { return }
                    let ownedData = data.withUnsafeBytes { Data($0) }
                    processingQueue.async { [weak self] in
                        self?.receive(ownedData)
                    }
                } completion: { [weak self] completion in
                    guard let self else { return }
                    processingQueue.async { [weak self] in
                        self?.complete(completion)
                    }
                }
                install(cancellation: cancellation)

                guard !isFinished else { return }
                let timeoutTask = Task.detached { [weak self, timeoutNanoseconds] in
                    try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                    guard !Task.isCancelled else { return }
                    self?.finish(self?.unavailableResult, cancellingRequest: true)
                }
                install(timeoutTask: timeoutTask)
            }
        } onCancel: {
            finish(unavailableResult, cancellingRequest: true)
        }
    }

    private var unavailableResult: PhotoEmbeddedMetadataResult {
        PhotoEmbeddedMetadataResult(status: .unavailable, metadata: nil)
    }

    private func receive(_ data: Data) {
        guard !isFinished else { return }
        let remainingByteCount = maximumByteCount - receivedByteCount
        guard remainingByteCount > 0 else {
            finish(unavailableResult, cancellingRequest: true)
            return
        }
        let acceptedData = data.count > remainingByteCount
            ? Data(data.prefix(remainingByteCount))
            : data
        receivedByteCount += acceptedData.count
        if let metadata = parser.consume(acceptedData, isFinal: false) {
            finish(
                PhotoEmbeddedMetadataResult(status: .available, metadata: metadata),
                cancellingRequest: true
            )
        } else if receivedByteCount == maximumByteCount {
            finish(unavailableResult, cancellingRequest: true)
        }
    }

    private func complete(_ completion: PhotoResourceCompletion) {
        guard !isFinished else { return }
        switch completion {
        case .success:
            if let metadata = parser.consume(Data(), isFinal: true) {
                finish(
                    PhotoEmbeddedMetadataResult(status: .available, metadata: metadata),
                    cancellingRequest: false
                )
            } else {
                finish(unavailableResult, cancellingRequest: false)
            }
        case .networkAccessRequired:
            finish(
                PhotoEmbeddedMetadataResult(status: .notLocal, metadata: nil),
                cancellingRequest: false
            )
        case .failure:
            finish(unavailableResult, cancellingRequest: false)
        }
    }

    private var isFinished: Bool {
        lock.withLock { state.result != nil }
    }

    private func install(
        continuation: CheckedContinuation<PhotoEmbeddedMetadataResult, Never>
    ) -> Bool {
        let completedResult = lock.withLock { () -> PhotoEmbeddedMetadataResult? in
            if let result = state.result {
                return result
            }
            state.continuation = continuation
            return nil
        }
        if let completedResult {
            continuation.resume(returning: completedResult)
            return false
        }
        return true
    }

    private func install(cancellation: @escaping @Sendable () -> Void) {
        let cancelImmediately = lock.withLock { () -> Bool in
            guard state.result == nil else {
                let shouldCancel = state.cancelWhenAvailable
                state.cancelWhenAvailable = false
                return shouldCancel
            }
            state.cancellation = cancellation
            return false
        }
        if cancelImmediately {
            cancellation()
        }
    }

    private func install(timeoutTask: Task<Void, Never>) {
        let cancelImmediately = lock.withLock { () -> Bool in
            guard state.result == nil else { return true }
            state.timeoutTask = timeoutTask
            return false
        }
        if cancelImmediately {
            timeoutTask.cancel()
        }
    }

    private func finish(
        _ result: PhotoEmbeddedMetadataResult?,
        cancellingRequest: Bool
    ) {
        guard let result else { return }
        let actions = lock.withLock {
            () -> (
                CheckedContinuation<PhotoEmbeddedMetadataResult, Never>?,
                (@Sendable () -> Void)?,
                Task<Void, Never>?
            ) in
            guard state.result == nil else { return (nil, nil, nil) }
            state.result = result
            let continuation = state.continuation
            state.continuation = nil
            let timeoutTask = state.timeoutTask
            state.timeoutTask = nil
            let cancellation = cancellingRequest ? state.cancellation : nil
            state.cancellation = nil
            if cancellingRequest, cancellation == nil {
                state.cancelWhenAvailable = true
            }
            return (continuation, cancellation, timeoutTask)
        }
        actions.2?.cancel()
        actions.1?()
        actions.0?.resume(returning: result)
    }
}

nonisolated final class IncrementalPhotoMetadataParser: @unchecked Sendable {
    private let source = CGImageSourceCreateIncremental(nil)
    private var data = Data()

    func consume(_ newData: Data, isFinal: Bool) -> PhotoEmbeddedMetadata? {
        data.append(newData)
        CGImageSourceUpdateData(source, data as CFData, isFinal)
        guard CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0).rawValue
                >= CGImageSourceStatus.statusIncomplete.rawValue,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary? else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? NSDictionary
        let metadata = PhotoEmbeddedMetadata(
            orientation: Self.integer(properties[kCGImagePropertyOrientation as String]),
            cameraMake: Self.bounded(Self.string(tiff?[kCGImagePropertyTIFFMake as String])),
            cameraModel: Self.bounded(Self.string(tiff?[kCGImagePropertyTIFFModel as String])),
            lensMake: Self.bounded(Self.string(exif?[kCGImagePropertyExifLensMake as String])),
            lensModel: Self.bounded(Self.string(exif?[kCGImagePropertyExifLensModel as String])),
            exposureTimeSeconds: Self.number(
                exif?[kCGImagePropertyExifExposureTime as String]
            ),
            fNumber: Self.number(exif?[kCGImagePropertyExifFNumber as String]),
            isoSpeedRatings: Self.integerArray(
                exif?[kCGImagePropertyExifISOSpeedRatings as String]
            ),
            focalLengthMillimeters: Self.number(
                exif?[kCGImagePropertyExifFocalLength as String]
            ),
            exposureBiasEV: Self.number(
                exif?[kCGImagePropertyExifExposureBiasValue as String]
            )
        )
        // Basic properties can appear before the embedded metadata payload.
        // Finish early only after both dictionaries we inspect are available.
        let embeddedDictionariesAvailable = (exif?.count ?? 0) > 0
            && (tiff?.count ?? 0) > 0
        guard isFinal || embeddedDictionariesAvailable else {
            return nil
        }
        return metadata
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func integerArray(_ value: Any?) -> [Int]? {
        (value as? [NSNumber])?.prefix(16).map(\.intValue)
    }

    private static func bounded(_ value: String?) -> String? {
        guard let value else { return nil }
        var end = value.startIndex
        var byteCount = 0
        while end < value.endIndex {
            let next = value.index(after: end)
            let nextByteCount = value[end..<next].utf8.count
            guard byteCount + nextByteCount <= 128 else { break }
            byteCount += nextByteCount
            end = next
        }
        return String(value[..<end])
    }
}

@Observable
@MainActor
final class PhotoService {
    nonisolated static let defaultPhotoCount = 5
    nonisolated static let maximumPhotoCount = 10

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let preferences: SharingPreferences
    private let library: any PhotoLibraryReading
    private let identifierNamespace: @MainActor () -> String
    private var requestGeneration: UInt64 = 0

    private(set) var authorizationStatus: PhotoAuthorizationState

    init(
        preferences: SharingPreferences,
        library: any PhotoLibraryReading = SystemPhotoLibraryReader(),
        identifierNamespace: @escaping @MainActor () -> String
    ) {
        self.preferences = preferences
        self.library = library
        self.identifierNamespace = identifierNamespace
        authorizationStatus = library.authorizationStatus
    }

    func refreshAuthorizationStatus() {
        authorizationStatus = library.authorizationStatus
    }

    /// Called only from the local sharing toggle. Remote requests call
    /// `recentPhotos` and therefore cannot originate a Photos prompt.
    func requestAuthorizationFromOperatorAction() async -> PhotoAuthorizationState {
        refreshAuthorizationStatus()
        if authorizationStatus == .notDetermined {
            authorizationStatus = await library.requestAuthorization()
        }
        return authorizationStatus
    }

    func cancelPendingRequestAfterConsentRevocation() {
        requestGeneration &+= 1
    }

    func suspendForCounterpartyChange() {
        requestGeneration &+= 1
    }

    func recentPhotos(
        limit: Int = defaultPhotoCount,
        includeEmbeddedMetadata: Bool = true,
        at date: Date = Date()
    ) async throws -> RecentPhotosSnapshot {
        guard (1...Self.maximumPhotoCount).contains(limit) else {
            throw PhotoServiceError.invalidRequest(
                "limit must be between 1 and \(Self.maximumPhotoCount)."
            )
        }
        guard preferences.photosEnabled else {
            throw PhotoServiceError.sharingDisabled
        }
        guard let counterpartyID = preferences.counterpartyID else {
            throw PhotoServiceError.identityUnavailable
        }

        refreshAuthorizationStatus()
        switch authorizationStatus {
        case .notDetermined:
            throw PhotoServiceError.permissionNotRequested
        case .denied:
            throw PhotoServiceError.permissionDenied
        case .restricted:
            throw PhotoServiceError.permissionRestricted
        case .limited, .full:
            break
        }

        let namespace = identifierNamespace()
        guard !namespace.isEmpty else {
            throw PhotoServiceError.identityUnavailable
        }
        let requestGeneration = self.requestGeneration

        let fetched: [PhotoLibraryAsset]
        do {
            fetched = try await library.fetchRecentPhotos(
                limit: limit + 1,
                embeddedMetadataLimit: includeEmbeddedMetadata ? limit : 0
            )
        } catch {
            throw PhotoServiceError.libraryUnavailable(error.localizedDescription)
        }
        guard requestGeneration == self.requestGeneration,
              preferences.photosEnabled else {
            throw PhotoServiceError.sharingDisabled
        }
        guard preferences.counterpartyID == counterpartyID,
              identifierNamespace() == namespace else {
            throw PhotoServiceError.identityUnavailable
        }
        let selected = fetched.prefix(limit)
        let photos = selected.map { asset in
            RecentPhotoMetadata(
                assetID: Self.pairwiseAssetID(
                    localIdentifier: asset.localIdentifier,
                    namespace: namespace
                ),
                createdAt: asset.creationDate.map(Self.timestampFormatter.string),
                modifiedAt: asset.modificationDate.map(Self.timestampFormatter.string),
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                mediaSubtypes: asset.mediaSubtypes,
                sourceTypes: asset.sourceTypes,
                uniformTypeIdentifier: asset.uniformTypeIdentifier,
                location: asset.location,
                embeddedMetadataStatus: includeEmbeddedMetadata
                    ? asset.embeddedMetadataStatus
                    : .notRequested,
                embeddedMetadata: includeEmbeddedMetadata ? asset.embeddedMetadata : nil
            )
        }
        return RecentPhotosSnapshot(
            capturedAt: Self.timestampFormatter.string(from: date),
            authorization: authorizationStatus,
            hiddenAssetsExcluded: true,
            iCloudDownloadsAllowed: false,
            requestedLimit: limit,
            returnedCount: photos.count,
            truncated: fetched.count > limit,
            photos: photos
        )
    }

    private nonisolated static func pairwiseAssetID(
        localIdentifier: String,
        namespace: String
    ) -> String {
        let digest = SHA256.hash(
            data: Data((namespace + "\u{0}" + localIdentifier).utf8)
        )
        return "photo_" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

private nonisolated struct RecentPhotosRequest: Decodable, Sendable {
    let limit: Int?
    let includeEmbeddedMetadata: Bool?

    enum CodingKeys: String, CodingKey {
        case limit
        case includeEmbeddedMetadata = "include_embedded_metadata"
    }
}

@MainActor
struct PhotoPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["list_recent"]
    let toolDefinitions = [
        PlatformToolDefinition.make(
            name: "ios_recent_photos",
            description: "List bounded metadata for the most recent visible photos in the active iOS companion. The operator must enable this source locally. Results can include dates, dimensions, favorite state, saved location, and selected camera, lens, and exposure metadata when the original is already on-device. Photo pixels, hidden assets, raw Photos identifiers, and iCloud downloads are excluded.",
            method: "list_recent",
            tags: ["ios", "photos", "context", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "limit": {
                  "type": "integer",
                  "minimum": 1,
                  "maximum": 10,
                  "default": 5,
                  "description": "Maximum number of recent visible photos to return."
                },
                "include_embedded_metadata": {
                  "type": "boolean",
                  "default": true,
                  "description": "Read selected EXIF/TIFF camera metadata only when the underlying image is already local."
                }
              }
            }
            """
        ),
    ]

    private let service: PhotoService

    init(service: PhotoService) {
        self.service = service
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard method == "list_recent" else {
            throw PhotoServiceError.unsupportedMethod(method)
        }
        let allowedParameters: Set<String> = ["limit", "include_embedded_metadata"]
        guard Set(params.keys).isSubset(of: allowedParameters) else {
            throw PhotoServiceError.invalidRequest("unsupported parameters were supplied.")
        }
        let request: RecentPhotosRequest
        do {
            request = try decodePlatformParams(RecentPhotosRequest.self, from: params)
        } catch {
            throw PhotoServiceError.invalidRequest("parameters do not match the advertised schema.")
        }
        return try AnyCodable.fromEncodable(await service.recentPhotos(
            limit: request.limit ?? PhotoService.defaultPhotoCount,
            includeEmbeddedMetadata: request.includeEmbeddedMetadata ?? true
        ))
    }
}
