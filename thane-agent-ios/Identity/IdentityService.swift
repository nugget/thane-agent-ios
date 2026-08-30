import Foundation
import os

@Observable
@MainActor
final class IdentityService {
    private(set) var evidence: ThaneIdentityEvidence?
    private(set) var sourceURL: URL?
    private(set) var isRefreshing = false
    private(set) var lastError: String?

    var onEvidenceUpdated: ((ThaneIdentityEvidence) -> Void)?
    var onRefreshFailed: (() -> Void)?

    private let fetcher: any IdentityEvidenceFetching
    private let logger = Logger(
        subsystem: "info.nugget.thane-agent-ios",
        category: "identity"
    )
    private var refreshTask: Task<Void, Never>?
    private var currentRefreshID: UUID?

    init(fetcher: any IdentityEvidenceFetching = URLSessionIdentityFetcher()) {
        self.fetcher = fetcher
    }

    func refresh(from baseURL: URL, token: String) {
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else { return }

        refreshTask?.cancel()
        if sourceURL != baseURL {
            evidence = nil
            lastError = nil
        }
        sourceURL = baseURL
        isRefreshing = true
        let refreshID = UUID()
        currentRefreshID = refreshID

        refreshTask = Task { [weak self, fetcher] in
            do {
                let evidence = try await fetcher.fetch(from: baseURL, token: trimmedToken)
                try Task.checkCancellation()
                guard let self,
                      self.sourceURL == baseURL,
                      self.currentRefreshID == refreshID else {
                    return
                }
                self.evidence = evidence
                self.lastError = nil
                self.isRefreshing = false
                self.refreshTask = nil
                self.currentRefreshID = nil
                self.logger.info("Refreshed presented Thane identity evidence")
                self.onEvidenceUpdated?(evidence)
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.sourceURL == baseURL,
                      self.currentRefreshID == refreshID else {
                    return
                }
                self.lastError = error.localizedDescription
                self.isRefreshing = false
                self.refreshTask = nil
                self.currentRefreshID = nil
                self.logger.error(
                    "Identity evidence refresh failed: \(error.localizedDescription, privacy: .public)"
                )
                self.onRefreshFailed?()
            }
        }
    }

    func evidence(for baseURL: URL?) -> ThaneIdentityEvidence? {
        guard sourceURL == baseURL else { return nil }
        return evidence
    }
}
