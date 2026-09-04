import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Platform router")
@MainActor
struct PlatformRouterTests {
    @Test("Capability registration is deterministic")
    func sortedCapabilities() {
        let router = PlatformServiceRouter()
        router.register(capability: "ios.zeta", handler: StubHandler())
        router.register(capability: "ios.alpha", handler: StubHandler())

        #expect(router.capabilities.map(\.name) == ["ios.alpha", "ios.zeta"])
    }

    @Test("Unknown capabilities return a structured error")
    func unknownCapability() async {
        let response = await PlatformServiceRouter().handle(request: PlatformRequest(
            id: 42,
            type: "platform_request",
            capability: "ios.missing",
            method: "read",
            params: nil
        ))

        #expect(response.id == 42)
        #expect(response.success == false)
        #expect(response.error?.code == "unknown_capability")
    }
}

@MainActor
private struct StubHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["read"]

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        AnyCodable(["ok": true])
    }
}
