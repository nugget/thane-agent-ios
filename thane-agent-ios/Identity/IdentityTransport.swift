import Foundation

@MainActor
protocol IdentityEvidenceFetching {
    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence
}

nonisolated enum IdentityFetchError: LocalizedError, Sendable, Equatable {
    case invalidResponse
    case unsupportedSchema(Int)
    case rejected(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Thane returned invalid identity evidence."
        case .unsupportedSchema(let version):
            "Thane returned unsupported identity schema version \(version)."
        case .rejected(let status, let message):
            "Thane identity evidence was unavailable (HTTP \(status)): \(message)"
        }
    }
}

@MainActor
final class URLSessionIdentityFetcher: IdentityEvidenceFetching {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        let request = Self.request(baseURL: baseURL, token: token)
        let (data, response) = try await session.data(for: request)
        return try Self.evidence(from: data, response: response)
    }

    nonisolated static func request(baseURL: URL, token: String) -> URLRequest {
        let endpoint = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("identity")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    nonisolated static func evidence(
        from data: Data,
        response: URLResponse
    ) throws -> ThaneIdentityEvidence {
        guard let response = response as? HTTPURLResponse else {
            throw IdentityFetchError.invalidResponse
        }
        guard response.statusCode == 200 else {
            throw IdentityFetchError.rejected(
                status: response.statusCode,
                message: safeErrorMessage(from: data)
            )
        }
        let evidence = try ThaneIdentityCoding.decoder().decode(
            ThaneIdentityEvidence.self,
            from: data
        )
        guard evidence.schemaVersion == 1 else {
            throw IdentityFetchError.unsupportedSchema(evidence.schemaVersion)
        }
        return evidence
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
