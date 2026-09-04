import Foundation

@Observable
@MainActor
final class AppState {
    let appPreferences: AppPreferences
    private(set) var profiles: [AgentProfile]
    private(set) var activeProfile: AgentProfile

    private let defaults: UserDefaults
    private let makeProfile: @MainActor (String, UserDefaults) -> AgentProfile
    private var removalsInFlight: Set<ObjectIdentifier> = []

    init(
        appPreferences: AppPreferences = AppPreferences(),
        profiles: [AgentProfile]? = nil,
        activeProfileID: String? = nil,
        defaults: UserDefaults = .standard,
        makeProfile: @escaping @MainActor (String, UserDefaults) -> AgentProfile
            = { AgentProfile.make(profileID: $0, defaults: $1) }
    ) {
        self.makeProfile = makeProfile
        let resolvedProfiles = profiles ?? AgentProfileRoster
            .resolveProfileIDs(in: defaults)
            .map { makeProfile($0, defaults) }
        precondition(
            !resolvedProfiles.isEmpty,
            "AppState requires at least one agent profile."
        )
        precondition(
            Set(resolvedProfiles.map(\.id)).count == resolvedProfiles.count,
            "Agent profile IDs must be unique."
        )

        self.appPreferences = appPreferences
        self.defaults = defaults
        self.profiles = resolvedProfiles

        let requestedID = activeProfileID ?? AgentProfileRoster.activeProfileID(in: defaults)
        activeProfile = resolvedProfiles.first(where: { $0.id == requestedID })
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

    func selectProfile(_ profile: AgentProfile) {
        guard profiles.contains(where: { $0 === profile }) else { return }
        activeProfile = profile
        AgentProfileRoster.setActiveProfileID(profile.id, in: defaults)
    }

    /// Mints an additional agent profile with its own storage scope.
    @discardableResult
    func addProfile() -> AgentProfile {
        let profileID = AgentProfileRoster.appendProfileID(in: defaults)
        let profile = makeProfile(profileID, defaults)
        profiles.append(profile)
        return profile
    }

    /// Removes an agent profile and erases its local state.
    ///
    /// Returns false without destroying anything when the profile cannot be
    /// removed. The last profile is refused *before* teardown begins, and a
    /// failed teardown stops short of dropping the roster entry — the profile's
    /// connection ID is what names its Keychain accounts, so discarding it
    /// while the token or pin survives would strand them permanently.
    @discardableResult
    func removeProfile(_ profile: AgentProfile) async -> Bool {
        // Teardown suspends, and @MainActor is reentrant across a suspension,
        // so the last-profile guard cannot be evaluated once and trusted.
        // Removals already in flight are reserved against the count here so a
        // concurrent removal is refused before it tears anything down, rather
        // than discovering the violation on the far side of the await.
        let identifier = ObjectIdentifier(profile)
        guard !removalsInFlight.contains(identifier),
              profiles.contains(where: { $0 === profile }),
              profiles.count - removalsInFlight.count > 1 else {
            return false
        }
        removalsInFlight.insert(identifier)
        defer { removalsInFlight.remove(identifier) }

        await profile.removeConnection()
        guard profile.configurationError == nil,
              profiles.contains(where: { $0 === profile }) else {
            return false
        }

        profiles.removeAll { $0 === profile }
        AgentProfileRoster.removeProfileID(profile.id, in: defaults)
        if activeProfile === profile {
            // Never promote a profile whose own teardown is still suspended —
            // with three or more profiles the surviving candidate at index 0 may
            // itself be mid-removal, which would briefly surface a partially
            // destroyed agent as the active one.
            activeProfile = profiles.first {
                !removalsInFlight.contains(ObjectIdentifier($0))
            } ?? profiles[0]
            AgentProfileRoster.setActiveProfileID(activeProfile.id, in: defaults)
        }
        return true
    }
}
