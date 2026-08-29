import Foundation
import Testing
@testable import thane_agent_ios

@Suite("Realtime protocol")
struct ProtocolTypesTests {
    @Test("Authentication explicitly negotiates the platform envelope")
    func authProtocolField() throws {
        let data = try JSONEncoder().encode(AuthMessage(
            type: "auth",
            token: "secret",
            clientName: "Thane for iOS",
            clientID: "client-id",
            connectionProtocol: WSEndpoint.platformProtocol
        ))
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )

        #expect(object["protocol"] == "platform")
        #expect(object["client_name"] == "Thane for iOS")
        #expect(object["client_id"] == "client-id")
    }

    @Test("Tool definitions preserve their exact JSON Schema")
    func toolSchema() throws {
        let definition = PlatformToolDefinition.make(
            name: "example",
            description: "Example",
            method: "read",
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "required": ["query"],
              "properties": {
                "query": { "type": "string" }
              }
            }
            """
        )

        #expect(definition.inputSchema["type"]?.value as? String == "object")
        #expect(definition.inputSchema["additionalProperties"]?.value as? Bool == false)
        let properties = try #require(
            definition.inputSchema["properties"]?.value as? [String: Any]
        )
        let query = try #require(properties["query"] as? [String: Any])
        #expect(query["type"] as? String == "string")
    }

    @Test("AnyCodable round-trips nested JSON")
    func anyCodableRoundTrip() throws {
        let original = AnyCodable([
            "enabled": true,
            "values": [1, 2, 3],
            "name": "iOS",
        ] as [String: Any])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let object = try #require(decoded.value as? [String: Any])

        #expect(object["enabled"] as? Bool == true)
        #expect(object["name"] as? String == "iOS")
        #expect(object["values"] as? [Int64] == [1, 2, 3])
    }
}
