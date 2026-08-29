import Foundation

nonisolated enum ServerAddress {
    /// Parses an operator-supplied Thane base URL. Production connections must
    /// use HTTPS. Plain HTTP is limited to loopback for simulator development;
    /// TLS trust evaluation itself is never bypassed.
    static func parse(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let normalizedHost = if host.hasPrefix("[") && host.hasSuffix("]") {
            String(host.dropFirst().dropLast())
        } else {
            host
        }
        let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1"]
        guard scheme == "https" || (scheme == "http" && loopbackHosts.contains(normalizedHost)) else {
            return nil
        }

        components.scheme = scheme
        components.host = host.hasPrefix("[") ? host : normalizedHost
        return components.url
    }
}
