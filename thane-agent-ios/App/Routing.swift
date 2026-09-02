import Foundation

nonisolated enum AppSection: Hashable, Sendable {
    case chats
    case settings
}

nonisolated enum AppDestination: Hashable, Sendable {
    case conversations(counterpartyID: String)
    case conversation(counterpartyID: String, conversationID: String)
    case counterparty(counterpartyID: String)

    var counterpartyID: String {
        switch self {
        case .conversations(let counterpartyID),
             .conversation(let counterpartyID, _),
             .counterparty(let counterpartyID):
            counterpartyID
        }
    }

    var externalURL: URL? {
        guard (try? AppDestinationValidator.validate(self)) != nil else {
            return nil
        }

        let identity = AppDestinationValidator.percentEncodedIdentifier(counterpartyID)
        let path = switch self {
        case .conversations:
            "/agents/\(identity)/conversations"
        case .conversation(_, let conversationID):
            "/agents/\(identity)/conversations/\(AppDestinationValidator.percentEncodedIdentifier(conversationID))"
        case .counterparty:
            "/agents/\(identity)"
        }

        var components = URLComponents()
        components.scheme = "thane"
        components.host = "v1"
        components.percentEncodedPath = path
        return components.url
    }
}

nonisolated enum ThaneURLParseError: LocalizedError, Equatable, Sendable {
    case tooLong
    case invalidScheme
    case unsupportedVersion
    case embeddedData
    case unknownDestination
    case invalidCounterpartyID
    case invalidConversationID

    var errorDescription: String? {
        switch self {
        case .tooLong:
            "The link is longer than Thane permits."
        case .invalidScheme:
            "This is not a Thane app link."
        case .unsupportedVersion:
            "This version of the Thane app link is not supported."
        case .embeddedData:
            "Thane app links may contain routing identifiers only. Credentials, query data, and private payloads are not accepted."
        case .unknownDestination:
            "This Thane app link does not name a supported destination."
        case .invalidCounterpartyID:
            "The link does not contain a valid bounded Thane identity identifier."
        case .invalidConversationID:
            "The link does not contain a valid bounded conversation identifier."
        }
    }
}

nonisolated enum ThaneURLParser {
    private static let maximumURLLength = 2_048

    static func parse(_ url: URL) throws -> AppDestination {
        guard url.absoluteString.utf8.count <= maximumURLLength else {
            throw ThaneURLParseError.tooLong
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "thane" else {
            throw ThaneURLParseError.invalidScheme
        }
        guard components.host?.lowercased() == "v1" else {
            throw ThaneURLParseError.unsupportedVersion
        }
        guard components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            throw ThaneURLParseError.embeddedData
        }

        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix("/") else {
            throw ThaneURLParseError.unknownDestination
        }
        let encodedSegments = encodedPath.dropFirst().split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !encodedSegments.isEmpty,
              encodedSegments.allSatisfy({ !$0.isEmpty }),
              encodedSegments.first == "agents",
              encodedSegments.count >= 2 else {
            throw ThaneURLParseError.unknownDestination
        }
        let counterpartyID = try decodedIdentifier(
            encodedSegments[1],
            invalidError: .invalidCounterpartyID
        )

        let destination: AppDestination
        switch encodedSegments.count {
        case 2:
            destination = .counterparty(counterpartyID: counterpartyID)
        case 3 where encodedSegments[2] == "conversations":
            destination = .conversations(counterpartyID: counterpartyID)
        case 4 where encodedSegments[2] == "conversations":
            destination = .conversation(
                counterpartyID: counterpartyID,
                conversationID: try decodedIdentifier(
                    encodedSegments[3],
                    invalidError: .invalidConversationID
                )
            )
        default:
            throw ThaneURLParseError.unknownDestination
        }

        try AppDestinationValidator.validate(destination)
        return destination
    }

    private static func decodedIdentifier(
        _ value: Substring,
        invalidError: ThaneURLParseError
    ) throws -> String {
        guard AppDestinationValidator.hasValidEncodedSegmentSyntax(value),
              let decoded = String(value).removingPercentEncoding else {
            throw invalidError
        }
        return decoded
    }
}

nonisolated enum AppRouteIssueReason: Equatable, Sendable {
    case invalidLink(ThaneURLParseError)
    case identityMismatch
}

nonisolated struct AppRouteIdentity: Equatable, Sendable {
    let id: String
    let displayName: String

    init(_ counterparty: ThaneCounterparty) {
        id = counterparty.id
        displayName = counterparty.displayName
    }
}

nonisolated struct AppRouteIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let reason: AppRouteIssueReason
    let requestedCounterpartyID: String?
    let activeIdentity: AppRouteIdentity?
}

@Observable
@MainActor
final class AppRouter {
    var selectedSection: AppSection
    var chatPath: [AppDestination]
    var issue: AppRouteIssue?

    init(
        selectedSection: AppSection = .chats,
        chatPath: [AppDestination] = []
    ) {
        self.selectedSection = selectedSection
        self.chatPath = chatPath
    }

    func open(_ url: URL, activeCounterparty: ThaneCounterparty?) {
        do {
            navigate(
                to: try ThaneURLParser.parse(url),
                activeCounterparty: activeCounterparty
            )
        } catch let error as ThaneURLParseError {
            issue = AppRouteIssue(
                reason: .invalidLink(error),
                requestedCounterpartyID: nil,
                activeIdentity: nil
            )
        } catch {
            issue = AppRouteIssue(
                reason: .invalidLink(.unknownDestination),
                requestedCounterpartyID: nil,
                activeIdentity: nil
            )
        }
    }

    func navigate(
        to destination: AppDestination,
        activeCounterparty: ThaneCounterparty?
    ) {
        do {
            try AppDestinationValidator.validate(destination)
        } catch let error as ThaneURLParseError {
            issue = AppRouteIssue(
                reason: .invalidLink(error),
                requestedCounterpartyID: nil,
                activeIdentity: nil
            )
            return
        } catch {
            issue = AppRouteIssue(
                reason: .invalidLink(.unknownDestination),
                requestedCounterpartyID: nil,
                activeIdentity: nil
            )
            return
        }

        guard activeCounterparty?.id == destination.counterpartyID else {
            issue = AppRouteIssue(
                reason: .identityMismatch,
                requestedCounterpartyID: destination.counterpartyID,
                activeIdentity: activeCounterparty.map(AppRouteIdentity.init)
            )
            return
        }

        issue = nil
        selectedSection = .chats
        switch destination {
        case .conversations:
            chatPath.removeAll()
        case .conversation, .counterparty:
            chatPath = [destination]
        }
    }

    func showSettings() {
        selectedSection = .settings
    }

    func reconcile(activeCounterpartyID: String?) {
        guard chatPath.allSatisfy({ $0.counterpartyID == activeCounterpartyID }) else {
            chatPath.removeAll()
            return
        }
    }
}

private nonisolated enum AppDestinationValidator {
    private static let maximumCounterpartyIDLength = 512
    private static let maximumConversationIDLength = 128

    static func validate(_ destination: AppDestination) throws {
        guard isValidCounterpartyID(destination.counterpartyID) else {
            throw ThaneURLParseError.invalidCounterpartyID
        }
        if case .conversation(_, let conversationID) = destination,
           !isValidConversationID(conversationID) {
            throw ThaneURLParseError.invalidConversationID
        }
    }

    static func percentEncodedIdentifier(_ value: String) -> String {
        value.utf8.map { byte in
            if isUnreserved(byte) {
                String(UnicodeScalar(Int(byte))!)
            } else {
                String(format: "%%%02X", byte)
            }
        }
        .joined()
    }

    static func hasValidEncodedSegmentSyntax(_ value: Substring) -> Bool {
        let bytes = Array(value.utf8)
        var index = 0
        while index < bytes.count {
            if isUnreserved(bytes[index]) {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "%"),
                  index + 2 < bytes.count,
                  isHexDigit(bytes[index + 1]),
                  isHexDigit(bytes[index + 2]) else {
                return false
            }
            index += 3
        }
        return true
    }

    private static func isValidCounterpartyID(_ value: String) -> Bool {
        isValidIdentifier(value, maximumLength: maximumCounterpartyIDLength) { byte in
            isUnreserved(byte) || [
                UInt8(ascii: ":"),
                UInt8(ascii: "+"),
                UInt8(ascii: "/"),
                UInt8(ascii: "="),
            ].contains(byte)
        }
    }

    private static func isValidConversationID(_ value: String) -> Bool {
        isValidIdentifier(value, maximumLength: maximumConversationIDLength, allowed: isUnreserved)
    }

    private static func isValidIdentifier(
        _ value: String,
        maximumLength: Int,
        allowed: (UInt8) -> Bool
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              bytes.count <= maximumLength,
              value != ".",
              value != ".." else {
            return false
        }
        return bytes.allSatisfy(allowed)
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "a")...UInt8(ascii: "z"),
             UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "-"), UInt8(ascii: "."),
             UInt8(ascii: "_"), UInt8(ascii: "~"):
            true
        default:
            false
        }
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"),
             UInt8(ascii: "A")...UInt8(ascii: "F"),
             UInt8(ascii: "a")...UInt8(ascii: "f"):
            true
        default:
            false
        }
    }
}
