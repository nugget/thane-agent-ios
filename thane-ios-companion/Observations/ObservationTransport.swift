import Foundation
import os

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
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Thane returned an invalid observation response."
        case .rejected(let status, let message):
            "Thane rejected observations (HTTP \(status)): \(message)"
        case .transferFailed(let reason):
            "The observation upload could not complete: \(reason)"
        }
    }
}

/// Owns the background `URLSession` for one profile and bridges its
/// delegate callbacks back to the `async` call that started the transfer.
///
/// A background session is the only upload that survives suspension: the
/// transfer is handed to `nsurlsessiond` out of process, continues while
/// the app is not running, and relaunches the app on completion. A
/// `beginBackgroundTask` assertion, which is what this replaces, is a stay
/// of execution — when it expires the socket dies with the process.
///
/// The consequence is that a completion can arrive in a later launch than
/// the one that started it, with no continuation left to resume. That is
/// safe rather than lossy: the outbox only drops events after an accepted
/// response, and ingestion is idempotent on `event_id`, so an unobserved
/// completion costs one repeated POST and never a lost or doubled
/// observation.
final class ObservationBackgroundSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let registryLock = NSLock()
    // Every read and write goes through registryLock below; the annotation
    // records that the invariant is held by the lock rather than by isolation.
    nonisolated(unsafe) private static var registry: [String: ObservationBackgroundSession] = [:]

    /// One session per identifier per process. `URLSession` traps if two
    /// background sessions share an identifier, and a profile rebuilt in
    /// place would otherwise ask for a second.
    static func shared(identifier: String) -> ObservationBackgroundSession {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[identifier] { return existing }
        let created = ObservationBackgroundSession(identifier: identifier)
        registry[identifier] = created
        return created
    }

    /// Stores the system's completion handler for a session whose events
    /// were delivered while the app was not running. `UIKit` requires it be
    /// called once the session reports it has finished.
    static func storeCompletionHandler(_ handler: @escaping @Sendable () -> Void, for identifier: String) {
        shared(identifier: identifier).setCompletionHandler(handler)
    }

    let identifier: String
    private let logger = Logger(
        subsystem: "info.nugget.thane-ios-companion",
        category: "observations"
    )
    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var continuations: [Int: CheckedContinuation<(Data, URLResponse), Error>] = [:]
    private var completionHandler: (@Sendable () -> Void)?

    private init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        // Relaunch the app when a transfer finishes while it is not running;
        // this is a wake source in its own right, independent of movement.
        configuration.sessionSendsLaunchEvents = true
        // Observations are small and time-sensitive. Discretionary transfers
        // are deferred to the system's convenience, which for a companion
        // whose whole purpose is freshness is the wrong trade.
        configuration.isDiscretionary = false
        configuration.allowsCellularAccess = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private func setCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        completionHandler = handler
        lock.unlock()
        _ = session
    }

    /// Uploads a body already written to `fileURL`. A background session
    /// refuses an in-memory body, which is also what lets the transfer
    /// outlive the process.
    func upload(request: URLRequest, fromFile fileURL: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: fileURL)
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            buffers[task.taskIdentifier] = Data()
            lock.unlock()
            task.resume()
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        let body = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        lock.unlock()

        guard let continuation else {
            // A transfer from an earlier launch. The outbox still holds its
            // events, so the next flush re-sends them and the server's
            // event_id idempotency absorbs the repeat.
            logger.notice("Background observation transfer completed with no waiting caller")
            return
        }
        if let error {
            continuation.resume(throwing: ObservationUploadError.transferFailed(error.localizedDescription))
            return
        }
        guard let response = task.response else {
            continuation.resume(throwing: ObservationUploadError.invalidResponse)
            return
        }
        continuation.resume(returning: (body, response))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = completionHandler
        completionHandler = nil
        lock.unlock()
        guard let handler else { return }
        DispatchQueue.main.async { handler() }
    }
}

@MainActor
final class URLSessionObservationUploader: ObservationUploading {
    private let backgroundSession: ObservationBackgroundSession

    /// The session identifier is scoped by profile for the same reason the
    /// outbox directory is: two profiles must not share transfer state.
    nonisolated static func sessionIdentifier(profileID: String) -> String {
        "info.nugget.thane-ios-companion.observations.\(profileID)"
    }

    init(profileID: String) {
        self.backgroundSession = .shared(identifier: Self.sessionIdentifier(profileID: profileID))
    }

    init(backgroundSession: ObservationBackgroundSession) {
        self.backgroundSession = backgroundSession
    }

    func upload(
        _ batch: ObservationBatch,
        to baseURL: URL,
        token: String
    ) async throws -> ObservationIngestResult {
        var request = try Self.request(for: batch, baseURL: baseURL, token: token)
        guard let body = request.httpBody else {
            throw ObservationUploadError.transferFailed("the batch produced no request body")
        }
        // A background upload task carries its body as a file, never inline.
        request.httpBody = nil
        let fileURL = try Self.writeBody(body)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let (data, response) = try await backgroundSession.upload(request: request, fromFile: fileURL)
        return try Self.result(from: data, response: response)
    }

    /// Writes the batch body somewhere the session can read it after this
    /// process is gone. File protection is `completeUntilFirstUserAuthentication`
    /// to match the outbox: readable after a reboot's first unlock, which is
    /// the window a background wake actually runs in.
    nonisolated static func writeBody(_ body: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("observation-uploads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try body.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return fileURL
    }

    nonisolated static func request(
        for batch: ObservationBatch,
        baseURL: URL,
        token: String
    ) throws -> URLRequest {
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
        return request
    }

    nonisolated static func result(
        from data: Data,
        response: URLResponse
    ) throws -> ObservationIngestResult {
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
