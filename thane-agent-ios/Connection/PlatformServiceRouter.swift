import Foundation
import os

nonisolated protocol PlatformServiceError: LocalizedError {
    var code: String { get }
}

@MainActor
protocol PlatformServiceHandler: Sendable {
    var version: String { get }
    var supportedMethods: [String] { get }
    var toolDefinitions: [PlatformToolDefinition] { get }
    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable
}

extension PlatformServiceHandler {
    var toolDefinitions: [PlatformToolDefinition] { [] }
}

@MainActor
final class PlatformServiceRouter {
    private let logger = Logger(
        subsystem: "info.nugget.thane-agent-ios",
        category: "platform"
    )
    private var handlers: [String: any PlatformServiceHandler] = [:]

    func register(capability: String, handler: any PlatformServiceHandler) {
        handlers[capability] = handler
    }

    var capabilities: [Capability] {
        handlers.keys.sorted().compactMap { name in
            guard let handler = handlers[name] else { return nil }
            let tools = handler.toolDefinitions
            return Capability(
                name: name,
                version: handler.version,
                methods: handler.supportedMethods,
                tools: tools.isEmpty ? nil : tools
            )
        }
    }

    func handle(request: PlatformRequest) async -> PlatformResponse {
        guard let handler = handlers[request.capability] else {
            logger.warning("Unknown capability: \(request.capability, privacy: .public)")
            return failure(
                request,
                code: "unknown_capability",
                message: "No handler for \(request.capability)"
            )
        }

        guard handler.supportedMethods.contains(request.method) else {
            logger.warning(
                "Unknown method: \(request.capability, privacy: .public).\(request.method, privacy: .public)"
            )
            return failure(
                request,
                code: "unknown_method",
                message: "Method \(request.method) is not supported by \(request.capability)"
            )
        }

        do {
            return PlatformResponse(
                id: request.id,
                type: "result",
                success: true,
                result: try await handler.handle(
                    method: request.method,
                    params: request.params ?? [:]
                ),
                error: nil
            )
        } catch {
            let code = (error as? any PlatformServiceError)?.code ?? "handler_error"
            logger.error(
                "Provider failed: \(request.capability, privacy: .public).\(request.method, privacy: .public), \(error.localizedDescription, privacy: .public)"
            )
            return failure(
                request,
                code: code,
                message: error.localizedDescription
            )
        }
    }

    private func failure(
        _ request: PlatformRequest,
        code: String,
        message: String
    ) -> PlatformResponse {
        PlatformResponse(
            id: request.id,
            type: "result",
            success: false,
            result: nil,
            error: WSError(code: code, message: message)
        )
    }
}
