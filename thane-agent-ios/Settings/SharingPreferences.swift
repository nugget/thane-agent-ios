import Foundation

nonisolated enum SystemContextCategory: String, CaseIterable, Identifiable, Sendable {
    case regional
    case device
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regional: "Time & Region"
        case .device: "Device State"
        case .network: "Network State"
        }
    }

    var detail: String {
        switch self {
        case .regional:
            "Current time, time zone, locale, languages, calendar, and hour format."
        case .device:
            "Device class, OS version, battery, Low Power Mode, and thermal state."
        case .network:
            "Connectivity, interface types, address-family support, and constrained or expensive status."
        }
    }
}

@Observable
@MainActor
final class SharingPreferences {
    private nonisolated static let keyPrefix = "sharing."
    private let defaults: UserDefaults

    var regionalEnabled: Bool {
        didSet { persist(regionalEnabled, key: SystemContextCategory.regional.rawValue) }
    }
    var deviceEnabled: Bool {
        didSet { persist(deviceEnabled, key: SystemContextCategory.device.rawValue) }
    }
    var networkEnabled: Bool {
        didSet { persist(networkEnabled, key: SystemContextCategory.network.rawValue) }
    }
    var locationEnabled: Bool {
        didSet { persist(locationEnabled, key: "location") }
    }
    var backgroundLocationEnabled: Bool {
        didSet { persist(backgroundLocationEnabled, key: "background-location") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        regionalEnabled = defaults.bool(forKey: Self.key(SystemContextCategory.regional.rawValue))
        deviceEnabled = defaults.bool(forKey: Self.key(SystemContextCategory.device.rawValue))
        networkEnabled = defaults.bool(forKey: Self.key(SystemContextCategory.network.rawValue))
        let storedLocationEnabled = defaults.bool(forKey: Self.key("location"))
        locationEnabled = storedLocationEnabled
        backgroundLocationEnabled = storedLocationEnabled
            && defaults.bool(forKey: Self.key("background-location"))
    }

    var enabledSystemCategories: Set<SystemContextCategory> {
        Set(SystemContextCategory.allCases.filter(isEnabled))
    }

    var hasEnabledData: Bool {
        !enabledSystemCategories.isEmpty || locationEnabled
    }

    func isEnabled(_ category: SystemContextCategory) -> Bool {
        switch category {
        case .regional: regionalEnabled
        case .device: deviceEnabled
        case .network: networkEnabled
        }
    }

    func setEnabled(_ enabled: Bool, for category: SystemContextCategory) {
        switch category {
        case .regional: regionalEnabled = enabled
        case .device: deviceEnabled = enabled
        case .network: networkEnabled = enabled
        }
    }

    private func persist(_ enabled: Bool, key: String) {
        defaults.set(enabled, forKey: Self.key(key))
    }

    private nonisolated static func key(_ suffix: String) -> String {
        keyPrefix + suffix
    }
}
