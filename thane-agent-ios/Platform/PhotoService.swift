import CryptoKit
import Foundation
import ImageIO
import Photos

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
        includeEmbeddedMetadata: Bool
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
        includeEmbeddedMetadata: Bool
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
            let embedded = includeEmbeddedMetadata
                ? await embeddedMetadata(for: asset)
                : PhotoEmbeddedMetadataResult(status: .notRequested, metadata: nil)
            let resource = Self.preferredResource(for: asset)
            photos.append(PhotoLibraryAsset(
                localIdentifier: asset.localIdentifier,
                creationDate: asset.creationDate,
                modificationDate: asset.modificationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                mediaSubtypes: Self.mediaSubtypeLabels(asset.mediaSubtypes),
                sourceTypes: Self.sourceTypeLabels(asset.sourceType),
                uniformTypeIdentifier: Self.bounded(resource?.uniformTypeIdentifier),
                location: Self.locationMetadata(asset.location),
                embeddedMetadataStatus: embedded.status,
                embeddedMetadata: embedded.metadata
            ))
        }
        return photos
    }

    private func embeddedMetadata(for asset: PHAsset) async -> PhotoEmbeddedMetadataResult {
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = false

        return await withCheckedContinuation { continuation in
            asset.requestContentEditingInput(with: options) { input, info in
                guard let url = input?.fullSizeImageURL else {
                    let isInCloud = info[PHContentEditingInputResultIsInCloudKey] as? Bool ?? false
                    continuation.resume(returning: PhotoEmbeddedMetadataResult(
                        status: isInCloud ? .notLocal : .unavailable,
                        metadata: nil
                    ))
                    return
                }
                continuation.resume(returning: Self.readEmbeddedMetadata(from: url))
            }
        }
    }

    private nonisolated static func readEmbeddedMetadata(
        from url: URL
    ) -> PhotoEmbeddedMetadataResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as NSDictionary? else {
            return PhotoEmbeddedMetadataResult(status: .unavailable, metadata: nil)
        }
        let exif = properties[kCGImagePropertyExifDictionary as String] as? NSDictionary
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? NSDictionary
        let metadata = PhotoEmbeddedMetadata(
            orientation: integer(properties[kCGImagePropertyOrientation as String]),
            cameraMake: bounded(string(tiff?[kCGImagePropertyTIFFMake as String])),
            cameraModel: bounded(string(tiff?[kCGImagePropertyTIFFModel as String])),
            lensMake: bounded(string(exif?[kCGImagePropertyExifLensMake as String])),
            lensModel: bounded(string(exif?[kCGImagePropertyExifLensModel as String])),
            exposureTimeSeconds: number(exif?[kCGImagePropertyExifExposureTime as String]),
            fNumber: number(exif?[kCGImagePropertyExifFNumber as String]),
            isoSpeedRatings: integerArray(
                exif?[kCGImagePropertyExifISOSpeedRatings as String]
            ),
            focalLengthMillimeters: number(exif?[kCGImagePropertyExifFocalLength as String]),
            exposureBiasEV: number(exif?[kCGImagePropertyExifExposureBiasValue as String])
        )
        return PhotoEmbeddedMetadataResult(status: .available, metadata: metadata)
    }

    private nonisolated static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .fullSizePhoto }
            ?? resources.first { $0.type == .photo }
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

    private nonisolated static func string(_ value: Any?) -> String? {
        value as? String
    }

    private nonisolated static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private nonisolated static func integer(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private nonisolated static func integerArray(_ value: Any?) -> [Int]? {
        (value as? [NSNumber])?.prefix(16).map(\.intValue)
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

private nonisolated struct PhotoEmbeddedMetadataResult: Sendable {
    let status: PhotoEmbeddedMetadataStatus
    let metadata: PhotoEmbeddedMetadata?
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
        guard preferences.counterpartyID != nil else {
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

        let fetched: [PhotoLibraryAsset]
        do {
            fetched = try await library.fetchRecentPhotos(
                limit: limit + 1,
                includeEmbeddedMetadata: includeEmbeddedMetadata
            )
        } catch {
            throw PhotoServiceError.libraryUnavailable(error.localizedDescription)
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
