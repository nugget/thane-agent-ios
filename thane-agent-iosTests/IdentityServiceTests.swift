import Foundation
import Testing

@testable import thane_agent_ios

@Suite("Identity service")
@MainActor
struct IdentityServiceTests {
    @Test("Refresh publishes presented evidence for its source endpoint")
    func refresh() async throws {
        let evidence = try IdentityTestFixture.evidence()
        let fetcher = StubIdentityFetcher(result: .success(evidence))
        let service = IdentityService(fetcher: fetcher)
        let baseURL = try #require(URL(string: "https://thane.example"))

        service.refresh(from: baseURL, token: " token ")
        try await waitUntil { !service.isRefreshing }

        #expect(service.evidence(for: baseURL) == evidence)
        #expect(service.evidence(for: URL(string: "https://other.example")) == nil)
        #expect(fetcher.receivedToken == "token")
        #expect(service.lastError == nil)
    }

    @Test("A refresh failure is additive to companion operation")
    func failure() async throws {
        let fetcher = StubIdentityFetcher(result: .failure(IdentityServiceTestError.expected))
        let service = IdentityService(fetcher: fetcher)
        let baseURL = try #require(URL(string: "https://thane.example"))

        service.refresh(from: baseURL, token: "token")
        try await waitUntil { !service.isRefreshing }

        #expect(service.evidence(for: baseURL) == nil)
        #expect(service.lastError == "Expected identity failure")
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for identity refresh")
    }
}

@MainActor
private final class StubIdentityFetcher: IdentityEvidenceFetching {
    let result: Result<ThaneIdentityEvidence, Error>
    private(set) var receivedToken: String?

    init(result: Result<ThaneIdentityEvidence, Error>) {
        self.result = result
    }

    func fetch(from baseURL: URL, token: String) async throws -> ThaneIdentityEvidence {
        receivedToken = token
        return try result.get()
    }
}

private enum IdentityServiceTestError: LocalizedError {
    case expected

    var errorDescription: String? { "Expected identity failure" }
}
