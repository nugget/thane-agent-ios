import Foundation
import os

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
    private(set) var serverVersion: String?
    private(set) var lastError: String?

    var registeredCapabilities: [Capability] = []
    var onPlatformRequest: ((PlatformRequest) async -> PlatformResponse)?

    private let logger = Logger(
        subsystem: "info.nugget.thane-agent-ios",
        category: "connection"
    )
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var readLoopTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeDetails: ConnectionDetails?
    private var currentAttemptID: UUID?
    private var intentionalDisconnect = false
    private var reconnectAttempt = 0
    private var nextID: Int64 = 1

    func connect(url: URL, token: String, clientID: String, clientName: String) {
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
        serverVersion = nil
        lastError = nil
    }

    private func beginConnection(_ details: ConnectionDetails) {
        reconnectTask?.cancel()
        reconnectTask = nil
        readLoopTask?.cancel()
        cleanupTransport(closeCode: .goingAway)

        let attemptID = UUID()
        currentAttemptID = attemptID

        state = .connecting
        lastError = nil
        providerID = nil
        account = nil
        serverVersion = nil

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: configuration)
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
        do {
            state = .authenticating
            let authRequired = try await receiveMessage()
            guard authRequired.envelope.type == "auth_required" else {
                throw ConnectionError.unexpectedMessage(
                    "Expected auth_required, got \(authRequired.envelope.type)"
                )
            }
            serverVersion = try? JSONDecoder()
                .decode(AuthRequiredMessage.self, from: authRequired.rawData)
                .version

            try await sendJSON(AuthMessage(
                type: "auth",
                token: details.token,
                clientName: details.clientName,
                clientID: details.clientID,
                connectionProtocol: WSEndpoint.platformProtocol
            ))

            let authResponse = try await receiveMessage()
            if authResponse.envelope.type == "auth_failed" {
                let message = try JSONDecoder()
                    .decode(AuthInvalidMessage.self, from: authResponse.rawData)
                    .message
                throw ConnectionError.authFailed(message)
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
            }

            try await registerCapabilities()
            reconnectAttempt = 0
            state = .connected
            lastError = nil
            logger.info("Connected to Thane")
            try await readLoop()
        } catch is CancellationError {
            return
        } catch {
            handleConnectionFailure(error, details: details, attemptID: attemptID)
        }
    }

    private func registerCapabilities() async throws {
        let message = RegisterCapabilitiesMessage(
            id: nextMessageID(),
            type: "register_capabilities",
            capabilities: registeredCapabilities
        )
        try await sendJSON(message)
    }

    private func readLoop() async throws {
        while !Task.isCancelled {
            let received = try await receiveMessage()
            switch received.envelope.type {
            case "ping":
                try await sendJSON(PongMessage(type: "pong"))
            case "result":
                continue
            case "platform_request":
                let request = try JSONDecoder().decode(
                    PlatformRequest.self,
                    from: received.rawData
                )
                Task { [weak self] in
                    await self?.respond(to: request)
                }
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

    private func respond(to request: PlatformRequest) async {
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

        do {
            try await sendJSON(response)
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

    private func sendJSON<T: Encodable>(_ value: T) async throws {
        let data = try JSONEncoder().encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConnectionError.encodingFailed
        }
        guard let webSocketTask else {
            throw ConnectionError.notConnected
        }
        try await webSocketTask.send(.string(text))
    }

    private func receiveMessage() async throws -> ReceivedMessage {
        guard let webSocketTask else {
            throw ConnectionError.notConnected
        }
        let message = try await webSocketTask.receive()
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
            self.beginConnection(details)
        }
    }

    private func cleanupTransport(closeCode: URLSessionWebSocketTask.CloseCode) {
        webSocketTask?.cancel(with: closeCode, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

nonisolated enum ConnectionError: LocalizedError {
    case notConnected
    case encodingFailed
    case decodingFailed
    case unexpectedMessage(String)
    case authFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to Thane."
        case .encodingFailed: "Failed to encode a WebSocket message."
        case .decodingFailed: "Failed to decode a WebSocket message."
        case .unexpectedMessage(let message): "Unexpected message: \(message)"
        case .authFailed(let message): "Authentication failed: \(message)"
        }
    }
}
