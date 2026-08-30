import Foundation
import Network
import UIKit

nonisolated struct SystemContextSnapshot: Codable, Equatable, Sendable {
    let capturedAt: String
    let regional: RegionalContext?
    let device: DeviceContext?
    let network: NetworkContext?

    enum CodingKeys: String, CodingKey {
        case capturedAt = "captured_at"
        case regional, device, network
    }
}

nonisolated struct RegionalContext: Codable, Equatable, Sendable {
    let timeZone: String
    let utcOffsetSeconds: Int
    let timeZoneAbbreviation: String?
    let locale: String
    let preferredLanguages: [String]
    let calendar: String
    let firstWeekday: Int
    let uses24HourTime: Bool
    let currencyCode: String?
    let measurementSystem: String

    enum CodingKeys: String, CodingKey {
        case timeZone = "time_zone"
        case utcOffsetSeconds = "utc_offset_seconds"
        case timeZoneAbbreviation = "time_zone_abbreviation"
        case locale
        case preferredLanguages = "preferred_languages"
        case calendar
        case firstWeekday = "first_weekday"
        case uses24HourTime = "uses_24_hour_time"
        case currencyCode = "currency_code"
        case measurementSystem = "measurement_system"
    }
}

nonisolated struct DeviceContext: Codable, Equatable, Sendable {
    let model: String
    let interfaceIdiom: String
    let systemName: String
    let systemVersion: String
    let batteryPercent: Int?
    let batteryState: String
    let lowPowerMode: Bool
    let thermalState: String

    enum CodingKeys: String, CodingKey {
        case model
        case interfaceIdiom = "interface_idiom"
        case systemName = "system_name"
        case systemVersion = "system_version"
        case batteryPercent = "battery_percent"
        case batteryState = "battery_state"
        case lowPowerMode = "low_power_mode"
        case thermalState = "thermal_state"
    }
}

nonisolated struct NetworkContext: Codable, Equatable, Sendable {
    let status: String
    let interfaceTypes: [String]
    let isExpensive: Bool
    let isConstrained: Bool
    let isUltraConstrained: Bool
    let supportsDNS: Bool
    let supportsIPv4: Bool
    let supportsIPv6: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case interfaceTypes = "interface_types"
        case isExpensive = "is_expensive"
        case isConstrained = "is_constrained"
        case isUltraConstrained = "is_ultra_constrained"
        case supportsDNS = "supports_dns"
        case supportsIPv4 = "supports_ipv4"
        case supportsIPv6 = "supports_ipv6"
    }

    init(path: NWPath) {
        status = switch path.status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requires_connection"
        @unknown default: "unknown"
        }

        let candidates: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "wifi"),
            (.cellular, "cellular"),
            (.wiredEthernet, "wired_ethernet"),
            (.loopback, "loopback"),
            (.other, "other"),
        ]
        interfaceTypes = candidates.compactMap { type, label in
            path.usesInterfaceType(type) ? label : nil
        }
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained
        isUltraConstrained = path.isUltraConstrained
        supportsDNS = path.supportsDNS
        supportsIPv4 = path.supportsIPv4
        supportsIPv6 = path.supportsIPv6
    }

    init(
        status: String,
        interfaceTypes: [String],
        isExpensive: Bool,
        isConstrained: Bool,
        isUltraConstrained: Bool,
        supportsDNS: Bool,
        supportsIPv4: Bool,
        supportsIPv6: Bool
    ) {
        self.status = status
        self.interfaceTypes = interfaceTypes
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.isUltraConstrained = isUltraConstrained
        self.supportsDNS = supportsDNS
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
    }
}

@Observable
@MainActor
final class NetworkContextMonitor {
    private(set) var current: NetworkContext?
    var onChange: (() -> Void)?

    private var monitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "info.nugget.thane-agent-ios.network-path")

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let snapshot = NetworkContext(path: path)
            Task { @MainActor [weak self] in
                guard self?.current != snapshot else { return }
                self?.current = snapshot
                self?.onChange?()
            }
        }
        monitor.start(queue: queue)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        current = nil
    }
}

nonisolated enum SystemContextServiceError: PlatformServiceError, Sendable {
    case noCategoriesEnabled
    case unsupportedMethod(String)

    var code: String {
        switch self {
        case .noCategoriesEnabled: "system_context_disabled"
        case .unsupportedMethod: "unknown_method"
        }
    }

    var errorDescription: String? {
        switch self {
        case .noCategoriesEnabled:
            "System Context sharing is disabled in the iOS companion app."
        case .unsupportedMethod(let method):
            "Unsupported System Context method: \(method)"
        }
    }
}

@MainActor
final class SystemContextService {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let preferences: SharingPreferences
    private let networkMonitor: NetworkContextMonitor
    private var changeHandler: (() -> Void)?
    private var notificationTasks: [Task<Void, Never>] = []

    init(
        preferences: SharingPreferences,
        networkMonitor: NetworkContextMonitor = NetworkContextMonitor()
    ) {
        self.preferences = preferences
        self.networkMonitor = networkMonitor
        networkMonitor.onChange = { [weak self] in
            self?.emitChange(for: .network)
        }
        if preferences.networkEnabled {
            networkMonitor.start()
        }
        UIDevice.current.isBatteryMonitoringEnabled = preferences.deviceEnabled
        startNotificationObservation()
    }

    func setNetworkObservationEnabled(_ enabled: Bool) {
        if enabled {
            networkMonitor.start()
        } else {
            networkMonitor.stop()
        }
    }

    func setDeviceObservationEnabled(_ enabled: Bool) {
        UIDevice.current.isBatteryMonitoringEnabled = enabled
    }

    func setChangeHandler(_ handler: @escaping () -> Void) {
        changeHandler = handler
    }

    func snapshot(at date: Date = Date()) throws -> SystemContextSnapshot {
        let enabled = preferences.enabledSystemCategories
        guard !enabled.isEmpty else {
            throw SystemContextServiceError.noCategoriesEnabled
        }

        return SystemContextSnapshot(
            capturedAt: Self.timestampFormatter.string(from: date),
            regional: enabled.contains(.regional) ? Self.regionalContext(at: date) : nil,
            device: enabled.contains(.device) ? Self.deviceContext() : nil,
            network: enabled.contains(.network) ? networkMonitor.current : nil
        )
    }

    private func startNotificationObservation() {
        let observations: [(Notification.Name, SystemContextCategory)] = [
            (Notification.Name("NSSystemTimeZoneDidChangeNotification"), .regional),
            (Notification.Name("NSCurrentLocaleDidChangeNotification"), .regional),
            (Notification.Name("NSProcessInfoPowerStateDidChangeNotification"), .device),
            (ProcessInfo.thermalStateDidChangeNotification, .device),
            (UIDevice.batteryLevelDidChangeNotification, .device),
            (UIDevice.batteryStateDidChangeNotification, .device),
        ]
        for (name, category) in observations {
            notificationTasks.append(Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(named: name) {
                    guard !Task.isCancelled else { return }
                    self?.emitChange(for: category)
                }
            })
        }
    }

    private func emitChange(for category: SystemContextCategory) {
        guard preferences.isEnabled(category) else { return }
        changeHandler?()
    }

    private nonisolated static func regionalContext(at date: Date) -> RegionalContext {
        let timeZone = TimeZone.autoupdatingCurrent
        let locale = Locale.autoupdatingCurrent
        let calendar = Calendar.autoupdatingCurrent
        let hourTemplate = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""

        return RegionalContext(
            timeZone: timeZone.identifier,
            utcOffsetSeconds: timeZone.secondsFromGMT(for: date),
            timeZoneAbbreviation: timeZone.abbreviation(for: date),
            locale: locale.identifier,
            preferredLanguages: Locale.preferredLanguages,
            calendar: String(describing: calendar.identifier),
            firstWeekday: calendar.firstWeekday,
            uses24HourTime: hourTemplate.contains("H") || hourTemplate.contains("k"),
            currencyCode: locale.currency?.identifier,
            measurementSystem: String(describing: locale.measurementSystem)
        )
    }

    private static func deviceContext() -> DeviceContext {
        let device = UIDevice.current
        let wasMonitoringBattery = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer {
            if !wasMonitoringBattery {
                device.isBatteryMonitoringEnabled = false
            }
        }
        let batteryPercent: Int? = device.batteryLevel >= 0
            ? Int((device.batteryLevel * 100).rounded())
            : nil
        let processInfo = ProcessInfo.processInfo

        return DeviceContext(
            model: device.model,
            interfaceIdiom: interfaceIdiomLabel(device.userInterfaceIdiom),
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            batteryPercent: batteryPercent,
            batteryState: batteryStateLabel(device.batteryState),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: thermalStateLabel(processInfo.thermalState)
        )
    }

    private static func interfaceIdiomLabel(_ idiom: UIUserInterfaceIdiom) -> String {
        switch idiom {
        case .phone: "phone"
        case .pad: "pad"
        case .tv: "tv"
        case .carPlay: "car_play"
        case .mac: "mac"
        case .vision: "vision"
        case .unspecified: "unspecified"
        @unknown default: "unknown"
        }
    }

    private static func batteryStateLabel(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: "unknown"
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        @unknown default: "unknown"
        }
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

@MainActor
struct SystemContextPlatformHandler: PlatformServiceHandler {
    let version = "1"
    let supportedMethods = ["get_snapshot"]
    let toolDefinitions = [
        PlatformToolDefinition.make(
            name: "ios_system_context",
            description: "Read the current operator-approved time, regional, device, and network context from the active iOS companion. Disabled categories are omitted.",
            method: "get_snapshot",
            tags: ["ios", "context", "read"],
            schemaJSON: """
            {
              "type": "object",
              "additionalProperties": false,
              "properties": {}
            }
            """
        ),
    ]

    private let service: SystemContextService

    init(service: SystemContextService) {
        self.service = service
    }

    func handle(method: String, params: [String: AnyCodable]) async throws -> AnyCodable {
        guard method == "get_snapshot" else {
            throw SystemContextServiceError.unsupportedMethod(method)
        }
        return try AnyCodable.fromEncodable(service.snapshot())
    }
}
