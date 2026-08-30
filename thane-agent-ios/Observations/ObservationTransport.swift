import Foundation

@MainActor
protocol ObservationUploading {
    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult
}

nonisolated enum ObservationUploadError: LocalizedError, Sendable {
    case invalidResponse
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Thane returned an invalid observation response."
        case .rejected(let status, let message):
            "Thane rejected observations (HTTP \(status)): \(message)"
        }
    }
}

@MainActor
final class URLSessionObservationUploader: ObservationUploading {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("companion")
            .appendingPathComponent("observations")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try ObservationCoding.encoder().encode(batch)

        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ObservationUploadError.invalidResponse
        }
        guard response.statusCode == 202 else {
            throw ObservationUploadError.rejected(
                status: response.statusCode,
                message: Self.safeErrorMessage(from: data)
            )
        }
        return try ObservationCoding.decoder().decode(ObservationIngestResult.self, from: data)
    }

    private nonisolated static func safeErrorMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            return envelope.error.message
        }
        return "No diagnostic message was returned."
    }
}
