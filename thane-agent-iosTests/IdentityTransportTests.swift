import Foundation
import Testing

@testable import thane_agent_ios

@Suite("Identity transport")
struct IdentityTransportTests {
    @Test("Request matches the native identity contract")
    func requestContract() throws {
        let request = URLSessionIdentityFetcher.request(
            baseURL: try #require(URL(string: "https://thane.example/base")),
            token: "secret-token"
        )

        #expect(request.url?.absoluteString == "https://thane.example/base/v1/identity")
        #expect(request.httpMethod == "GET")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
        #expect(request.httpBody == nil)
    }

    @Test("Successful evidence decodes the current schema")
    func acceptedResponse() throws {
        let response = try response(status: 200)

        let evidence = try URLSessionIdentityFetcher.evidence(
            from: IdentityTestFixture.json,
            response: response
        )

        #expect(evidence.instance.name == "pocket")
        #expect(evidence.core.currentCommit.oid == "fedcba9876543210fedcba9876543210fedcba98")
    }

    @Test("Unsupported schemas fail explicitly without decoding their body")
    func unsupportedSchema() throws {
        let data = Data(#"{"schema_version":2,"replacement_shape":true}"#.utf8)

        #expect(throws: IdentityFetchError.unsupportedSchema(2)) {
            _ = try URLSessionIdentityFetcher.evidence(from: data, response: try response(status: 200))
        }
    }

    @Test("Malformed schema-one evidence uses the operator-readable invalid response")
    func malformedCurrentSchema() throws {
        let data = Data(#"{"schema_version":1}"#.utf8)

        #expect(throws: IdentityFetchError.invalidResponse) {
            _ = try URLSessionIdentityFetcher.evidence(from: data, response: try response(status: 200))
        }
    }

    @Test("Malformed JSON is invalid")
    func malformedJSON() throws {
        let data = Data("{".utf8)

        #expect(throws: IdentityFetchError.invalidResponse) {
            _ = try URLSessionIdentityFetcher.evidence(from: data, response: try response(status: 200))
        }
    }

    @Test("Structured rejections remain operator-readable")
    func rejectedResponse() throws {
        let data = Data(
            #"{"error":{"code":"forbidden","message":"identity:read scope is required"}}"#.utf8
        )

        do {
            _ = try URLSessionIdentityFetcher.evidence(
                from: data,
                response: try response(status: 403)
            )
            Issue.record("Expected identity evidence to be rejected")
        } catch let error as IdentityFetchError {
            #expect(
                error.localizedDescription
                    == "Thane identity evidence was unavailable (HTTP 403): identity:read scope is required"
            )
        }
    }

    private func response(status: Int) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://thane.example/v1/identity"))
        return try #require(HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ))
    }
}
