import Foundation

@Observable
@MainActor
final class AppState {
    let appPreferences: AppPreferences
    private(set) var profiles: [AgentProfile]
    private(set) var activeProfile: AgentProfile

    init(
        appPreferences: AppPreferences = AppPreferences(),
        profiles: [AgentProfile]? = nil,
        activeProfileID: String? = nil
    ) {
        let resolvedProfiles = profiles ?? [AgentProfile()]
        precondition(
            !resolvedProfiles.isEmpty,
            "AppState requires at least one agent profile."
        )
        precondition(
            Set(resolvedProfiles.map(\.id)).count == resolvedProfiles.count,
            "Agent profile IDs must be unique."
        )

        self.appPreferences = appPreferences
        self.profiles = resolvedProfiles
        activeProfile = resolvedProfiles.first(where: { $0.id == activeProfileID })
            ?? resolvedProfiles[0]
    }

    var configuredProfiles: [AgentProfile] {
        profiles.filter(\.hasConnectionConfiguration)
    }

    func activate() {
        profiles.forEach { $0.activate() }
    }

    func enterBackground() {
        profiles.forEach { $0.enterBackground() }
    }
}
