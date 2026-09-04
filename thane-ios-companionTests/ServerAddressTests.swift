import Foundation
import Testing
@testable import ThaneIOSCompanion

@Suite("Server address validation")
struct ServerAddressTests {
    @Test("HTTPS server addresses are accepted")
    func acceptsHTTPS() throws {
        let url = try #require(ServerAddress.parse("  https://Thane.Example.com/base  "))
        #expect(url.scheme == "https")
        #expect(url.host == "thane.example.com")
        #expect(url.path == "/base")
    }

    @Test("Loopback HTTP is available for local development", arguments: [
        "http://localhost:8080",
        "http://127.0.0.1:8080",
        "http://[::1]:8080",
    ])
    func acceptsLoopbackHTTP(address: String) {
        #expect(ServerAddress.parse(address) != nil)
    }

    @Test("Remote plaintext and embedded credentials are rejected", arguments: [
        "http://thane.example.com",
        "http://192.168.1.10:8080",
        "https://operator:secret@thane.example.com",
        "https://thane.example.com?token=secret",
        "wss://thane.example.com",
    ])
    func rejectsUnsafeAddresses(address: String) {
        #expect(ServerAddress.parse(address) == nil)
    }

    @Test("Realtime URL retains a configured base path")
    func buildsRealtimeURL() throws {
        let base = try #require(URL(string: "https://thane.example.com/base"))
        #expect(
            WSEndpoint.realtimeURL(base: base).absoluteString
                == "wss://thane.example.com/base/v1/realtime/ws"
        )
    }
}
