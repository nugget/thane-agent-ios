import Foundation

nonisolated struct WSMessage: Codable, Sendable {
    let id: Int64?
    let type: String
    let success: Bool?
    let result: AnyCodable?
    let error: WSError?
}

nonisolated struct WSError: Codable, Sendable {
    let code: String
    let message: String
}

nonisolated struct AuthRequiredMessage: Codable, Sendable {
    let type: String
    let version: String
}

nonisolated struct AuthMessage: Codable, Sendable {
    let type: String
    let token: String
    let clientName: String
    let clientID: String
    let platform: String
    let appVersion: String
    let osVersion: String
    let connectionProtocol: String

    enum CodingKeys: String, CodingKey {
        case type, token
        case clientName = "client_name"
        case clientID = "client_id"
        case platform
        case appVersion = "app_version"
        case osVersion = "os_version"
        case connectionProtocol = "protocol"
    }
}

nonisolated struct AuthOKMessage: Codable, Sendable {
    let type: String
    let providerID: String
    let account: String
    let serverVersion: String?

    enum CodingKeys: String, CodingKey {
        case type, account
        case providerID = "provider_id"
        case serverVersion = "server_version"
    }
}

nonisolated struct AuthInvalidMessage: Codable, Sendable {
    let type: String
    let message: String
}

nonisolated struct Capability: Codable, Sendable {
    let name: String
    let version: String
    let methods: [String]
    let tools: [PlatformToolDefinition]?
}

/// A model-facing tool authored by this companion. The input schema is sent
/// verbatim to Thane, keeping the advertised contract beside its decoder.
nonisolated struct PlatformToolDefinition: Codable, Sendable {
    let name: String
    let description: String
    let method: String
    let tags: [String]?
    let inputSchema: [String: AnyCodable]

    enum CodingKeys: String, CodingKey {
        case name, description, method, tags
        case inputSchema = "input_schema"
    }

    static func make(
        name: String,
        description: String,
        method: String,
        tags: [String]? = nil,
        schemaJSON: String
    ) -> PlatformToolDefinition {
        guard let data = schemaJSON.data(using: .utf8),
              let schema = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              !schema.isEmpty else {
            preconditionFailure("invalid or empty tool schema JSON for \(name)")
        }
        return PlatformToolDefinition(
            name: name,
            description: description,
            method: method,
            tags: tags,
            inputSchema: schema
        )
    }
}

nonisolated struct RegisterCapabilitiesMessage: Codable, Sendable {
    let id: Int64
    let type: String
    let capabilities: [Capability]
}

nonisolated struct PlatformRequest: Codable, Sendable {
    let id: Int64
    let type: String
    let capability: String
    let method: String
    let params: [String: AnyCodable]?
}

nonisolated struct PlatformResponse: Codable, Sendable {
    let id: Int64
    let type: String
    let success: Bool
    let result: AnyCodable?
    let error: WSError?
}

nonisolated struct PongMessage: Codable, Sendable {
    let type: String
}

/// Type-erased JSON. `Any` is immutable after initialization, and encoding
/// and decoding create fresh value graphs, which is the serialization model
/// behind the unchecked conformance.
nonisolated struct AnyCodable: Codable, @unchecked Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    static func fromEncodable<T: Encodable>(_ value: T) throws -> AnyCodable {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int64.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            value = dictionary.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let value as Bool:
            try container.encode(value)
        case let value as Int64:
            try container.encode(value)
        case let value as Int:
            try container.encode(value)
        case let value as Double:
            try container.encode(value)
        case let value as String:
            try container.encode(value)
        case let value as [Any]:
            try container.encode(value.map(AnyCodable.init))
        case let value as [String: Any]:
            try container.encode(value.mapValues(AnyCodable.init))
        default:
            throw EncodingError.invalidValue(
                value,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Unsupported JSON type: \(type(of: value))"
                )
            )
        }
    }
}

nonisolated func decodePlatformParams<T: Decodable>(
    _ type: T.Type,
    from params: [String: AnyCodable]
) throws -> T {
    let data = try JSONEncoder().encode(params)
    return try JSONDecoder().decode(type, from: data)
}
