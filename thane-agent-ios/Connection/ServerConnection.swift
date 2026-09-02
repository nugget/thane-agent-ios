import Foundation
import os
import UIKit

nonisolated enum WSEndpoint {
    static let realtimePath = "v1/realtime/ws"
    static let platformProtocol = "platform"

    static func realtimeURL(base: URL) -> URL {
        let rawURL = base.appendingPathComponent(realtimePath)
        var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false)
        switch components?.scheme {
        case "https": components?.scheme = "wss"
        case "http": components?.scheme = "ws"
        default: break
        }
        return components?.url ?? rawURL
    }
}

private nonisolated struct ReceivedMessage: Sendable {
    let envelope: WSMessage
    let rawData: Data
}

private nonisolated struct ConnectionDetails: Sendable, Equatable {
    let url: URL
    let token: String
    let clientID: String
    let clientName: String
}

@Observable
@MainActor
final class ServerConnection {
    enum State: Equatable {
        case disconnected
        case connecting
        case authenticating
        case connected
        case reconnecting(attempt: Int)
    }

    private(set) var state: State = .disconnected
    private(set) var providerID: String?
    private(set) var account: String?
    private(set) var protocolVersion: String?
    private(set) var serverVersion: String?
    private(set) var serverStartedAt: Date?
    private(set) var transportCertificateChain: [TransportCertificate] = []
    private(set) var transportCertificateCapturedAt: Date?
    private(set) var transportCertificateEndpoint: URL?
    private(set) var lastError: String?

    var registeredCapabilities: [Capability] = []
    var onPlatformRequest: ((PlatformRequest) async -> PlatformResponse)?
    var onConnected: (() -> Void)?
    var onAuthenticationFailure: (() -> Void)?
    var onReconnectValidationRequested: (() -> Void)?

    private let logger = Logger(
        subsystem: "info.nugget.thane-agent-ios",
        category: "connection"
    )
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var trustObserver: ServerTrustObserver?
    private var pendingTransportCertificateChain: [TransportCertificate] = []
    private var hasPendingTransportCertificateObservation = false
    private var readLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var responseTasks: [UUID: Task<Void, Never>] = [:]
    private var activeDetails: ConnectionDetails?
    private var currentAttemptID: UUID?
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0
    private var nextID: Int64 = 1

    func connect(url: URL, token: String, clientID: String, clientName: String) {
        prepareForIdentityRefresh(from: url)
        let details = ConnectionDetails(
            url: url,
            token: token,
            clientID: clientID,
            clientName: clientName
        )
        activeDetails = details
        intentionalDisconnect = false
        reconnectAttempt = 0
        beginConnection(details)
    }

    func prepareForIdentityRefresh(from endpoint: URL) {
        guard transportCertificateCapturedAt != nil,
              transportCertificateEndpoint != endpoint else {
            return
        }
        clearRetainedTransportEvidence()
    }

    func disconnect() {
        intentionalDisconnect = true
        activeDetails = nil
        currentAttemptID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        readLoopTask?.cancel()
        readLoopTask = nil
        cleanupTransport(closeCode: .goingAway)
        state = .disconnected
        providerID = nil
        account = nil
        protocolVersion = nil
        serverVersion = nil
        serverStartedAt = nil
        pendingTransportCertificateChain = []
        hasPendingTransportCertificateObservation = false
    }

    private func beginConnection(_ details: ConnectionDetails) {
        reconnectTask?.cancel()
        reconnectTask = nil
        readLoopTask?.cancel()
        cleanupTransport(closeCode: .goingAway)

        let attemptID = UUID()
        currentAttemptID = attemptID

        state = .connecting
        providerID = nil
        account = nil
        protocolVersion = nil
        serverVersion = nil
        serverStartedAt = nil
        pendingTransportCertificateChain = []
        hasPendingTransportCertificateObservation = false

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        let trustObserver = ServerTrustObserver { [weak self] certificateChain in
            Task { @MainActor [weak self] in
                guard let self, self.currentAttemptID == attemptID else { return }
                self.recordTransportCertificateChain(certificateChain)
            }
        }
        self.trustObserver = trustObserver
        let session = URLSession(
            configuration: configuration,
            delegate: trustObserver,
            delegateQueue: nil
        )
        self.session = session

        var request = URLRequest(url: WSEndpoint.realtimeURL(base: details.url))
        request.timeoutInterval = 30
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        readLoopTask = Task { [weak self] in
            await self?.runConnection(details, attemptID: attemptID)
        }
    }

    private func runConnection(_ details: ConnectionDetails, attemptID: UUID) async {
        guard currentAttemptID == attemptID else { return }

        do {
            state = .authenticating
            let authRequired = try await receiveMessage(attemptID: attemptID)
            guard authRequired.envelope.type == "auth_required" else {
                throw ConnectionError.unexpectedMessage(
                    "Expected auth_required, got \(authRequired.envelope.type)"
                )
            }
            protocolVersion = try? JSONDecoder()
                .decode(AuthRequiredMessage.self, from: authRequired.rawData)
                .version

            try await sendJSON(AuthMessage(
                type: "auth",
                token: details.token,
                clientName: details.clientName,
                clientID: details.clientID,
                platform: "ios",
                appVersion: Self.appVersion,
                osVersion: UIDevice.current.systemVersion,
                connectionProtocol: WSEndpoint.platformProtocol
            ), attemptID: attemptID)

            let authResponse = try await receiveMessage(attemptID: attemptID)
            if authResponse.envelope.type == "auth_failed" {
                let message = try JSONDecoder()
                    .decode(AuthInvalidMessage.self, from: authResponse.rawData)
                    .message
                handleAuthenticationFailure(message)
                return
            }
            guard authResponse.envelope.type == "auth_ok" else {
                throw ConnectionError.unexpectedMessage(
                    "Expected auth_ok, got \(authResponse.envelope.type)"
                )
            }

            if let authOK = try? JSONDecoder().decode(
                AuthOKMessage.self,
                from: authResponse.rawData
            ) {
                providerID = authOK.providerID
                account = authOK.account
                serverVersion = authOK.serverVersion
                if let uptime = authOK.serverUptimeSeconds, uptime >= 0 {
                    serverStartedAt = Date().addingTimeInterval(-uptime)
                }
            }

            try await registerCapabilities(attemptID: attemptID)
            handleConnectionEstablished()
            try await readLoop(attemptID: attemptID)
        } catch is CancellationError {
            return
        } catch {
            handleConnectionFailure(error, details: details, attemptID: attemptID)
        }
    }

    private func registerCapabilities(attemptID: UUID) async throws {
        let message = RegisterCapabilitiesMessage(
            id: nextMessageID(),
            type: "register_capabilities",
            capabilities: registeredCapabilities
        )
        try await sendJSON(message, attemptID: attemptID)
    }

    private func readLoop(attemptID: UUID) async throws {
        while !Task.isCancelled {
            let received = try await receiveMessage(attemptID: attemptID)
            switch received.envelope.type {
            case "ping":
                try await sendJSON(PongMessage(type: "pong"), attemptID: attemptID)
            case "result":
                continue
            case "platform_request":
                let request = try JSONDecoder().decode(
                    PlatformRequest.self,
                    from: received.rawData
                )
                startResponseTask(request, attemptID: attemptID)
            case "companion_request":
                throw ConnectionError.unexpectedMessage(
                    "Server negotiated companion_request instead of platform_request"
                )
            default:
                logger.error(
                    "Unhandled WebSocket message: \(received.envelope.type, privacy: .public)"
                )
            }
        }
    }

    private func startResponseTask(_ request: PlatformRequest, attemptID: UUID) {
        let taskID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.respond(to: request, attemptID: attemptID)
            self.responseTasks[taskID] = nil
        }
        responseTasks[taskID] = task
    }

    private func respond(to request: PlatformRequest, attemptID: UUID) async {
        guard currentAttemptID == attemptID, !Task.isCancelled else { return }

        let response: PlatformResponse
        if let onPlatformRequest {
            response = await onPlatformRequest(request)
        } else {
            response = PlatformResponse(
                id: request.id,
                type: "result",
                success: false,
                result: nil,
                error: WSError(
                    code: "not_implemented",
                    message: "No platform request handler is registered"
                )
            )
        }

        guard currentAttemptID == attemptID, !Task.isCancelled else { return }

        do {
            try await sendJSON(response, attemptID: attemptID)
        } catch is CancellationError {
            return
        } catch ConnectionError.staleAttempt {
            return
        } catch {
            logger.error(
                "Failed to send platform response: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func nextMessageID() -> Int64 {
        defer { nextID += 1 }
        return nextID
    }

    private nonisolated static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return switch (version, build) {
        case let (version?, build?): "\(version) (\(build))"
        case let (version?, nil): version
        case let (nil, build?): build
        case (nil, nil): "unknown"
        }
    }

    private func sendJSON<T: Encodable>(_ value: T, attemptID: UUID) async throws {
        guard currentAttemptID == attemptID else {
            throw ConnectionError.staleAttempt
        }
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError.encodingFailed
        }
        guard currentAttemptID == attemptID, let webSocketTask else {
            throw ConnectionError.notConnected
        }
        try await webSocketTask.send(.string(text))
    }

    private func receiveMessage(attemptID: UUID) async throws -> ReceivedMessage {
        guard currentAttemptID == attemptID, let webSocketTask else {
            throw ConnectionError.notConnected
        }
        let message = try await webSocketTask.receive()
        guard currentAttemptID == attemptID, self.webSocketTask === webSocketTask else {
            throw ConnectionError.staleAttempt
        }
        let data: Data
        switch message {
        case .string(let text):
            guard let encoded = text.data(using: .utf8) else {
                throw ConnectionError.decodingFailed
            }
            data = encoded
        case .data(let encoded):
            data = encoded
        @unknown default:
            throw ConnectionError.decodingFailed
        }
        return ReceivedMessage(
            envelope: try JSONDecoder().decode(WSMessage.self, from: data),
            rawData: data
        )
    }

    private func handleConnectionFailure(
        _ error: Error,
        details: ConnectionDetails,
        attemptID: UUID
    ) {
        guard currentAttemptID == attemptID else { return }
        logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
        lastError = error.localizedDescription
        cleanupTransport(closeCode: .abnormalClosure)
        guard !intentionalDisconnect, activeDetails == details else {
            state = .disconnected
            return
        }

        reconnectAttempt += 1
        state = .reconnecting(attempt: reconnectAttempt)
        let delay = min(Double(1 << min(reconnectAttempt, 6)), 60)
        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                  !self.intentionalDisconnect,
                  self.currentAttemptID == attemptID,
                  self.activeDetails == details else {
                return
            }
            guard let onReconnectValidationRequested = self.onReconnectValidationRequested else {
                self.state = .disconnected
                self.activeDetails = nil
                self.currentAttemptID = nil
                return
            }
            onReconnectValidationRequested()
        }
    }

    func handleAuthenticationFailure(_ message: String) {
        let error = ConnectionError.authFailed(message)
        logger.error("Connection failed: \(error.localizedDescription, privacy: .public)")
        lastError = error.localizedDescription
        intentionalDisconnect = true
        activeDetails = nil
        currentAttemptID = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        cleanupTransport(closeCode: .policyViolation)
        state = .disconnected
        providerID = nil
        account = nil
        onAuthenticationFailure?()
    }

    func handleConnectionEstablished() {
        reconnectAttempt = 0
        state = .connected
        if hasPendingTransportCertificateObservation {
            publishTransportCertificateChain(pendingTransportCertificateChain)
        }
        pendingTransportCertificateChain = []
        hasPendingTransportCertificateObservation = false
        lastError = nil
        logger.info("Connected to Thane")
        onConnected?()
    }

    func resumeConnectionAfterIdentityValidation() {
        guard case .reconnecting = state,
              !intentionalDisconnect,
              let activeDetails else {
            return
        }
        beginConnection(activeDetails)
    }

    func recordTransportCertificateChain(
        _ certificateChain: [TransportCertificate],
        endpoint: URL? = nil
    ) {
        if state == .connected {
            publishTransportCertificateChain(certificateChain, endpoint: endpoint)
        } else {
            pendingTransportCertificateChain = certificateChain
            hasPendingTransportCertificateObservation = true
        }
    }

    func clearRetainedDiagnostics() {
        clearRetainedTransportEvidence()
        lastError = nil
    }

    private func publishTransportCertificateChain(
        _ certificateChain: [TransportCertificate],
        endpoint: URL? = nil
    ) {
        transportCertificateChain = certificateChain
        transportCertificateCapturedAt = Date()
        transportCertificateEndpoint = endpoint ?? activeDetails?.url
    }

    private func clearRetainedTransportEvidence() {
        transportCertificateChain = []
        transportCertificateCapturedAt = nil
        transportCertificateEndpoint = nil
    }

    private func cleanupTransport(closeCode: URLSessionWebSocketTask.CloseCode) {
        for task in responseTasks.values {
            task.cancel()
        }
        responseTasks.removeAll()
        webSocketTask?.cancel(with: closeCode, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        trustObserver = nil
        pendingTransportCertificateChain = []
        hasPendingTransportCertificateObservation = false
    }
}

nonisolated enum ConnectionError: LocalizedError {
    case notConnected
    case staleAttempt
    case encodingFailed
    case decodingFailed
    case unexpectedMessage(String)
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to Thane."
        case .staleAttempt: "The WebSocket connection attempt is no longer current."
        case .encodingFailed: "Failed to encode a WebSocket message."
        case .decodingFailed: "Failed to decode a WebSocket message."
        case .unexpectedMessage(let message): "Unexpected message: \(message)"
        case .authFailed(let message): "Authentication failed: \(message)"
        }
    }
}
