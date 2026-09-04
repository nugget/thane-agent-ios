import Foundation

/// The app-wide record of which agent profiles exist on this iPhone.
///
/// Profile identity is durable and one-way: `profileID` is SHA-256 hashed into
/// the observation outbox path and the inbox directory, and the `connectionID`
/// it seeds names the Keychain accounts. A profile ID may therefore be adopted
/// or minted, but never rewritten. Every profile records its own ID inside its
/// scoped keyspace so the roster can be rebuilt if the roster array is ever
/// lost, rather than minting a fresh ID over storage that is still on disk.
nonisolated enum AgentProfileRoster {
    static let rosterKey = "agents.roster"
    static let activeProfileIDKey = "agents.activeProfileID"
    static let scopingMigrationKey = "agents.scopedStorageMigrationComplete"

    /// Resolves the profiles for this installation, performing the one-time
    /// adoption of pre-scoping global keys when required. Always returns at
    /// least one profile ID.
    static func resolveProfileIDs(in defaults: UserDefaults) -> [String] {
        if let stored = storedRoster(in: defaults), !stored.isEmpty {
            return stored
        }

        // The roster array is missing or unreadable. Anchors are the authority:
        // rebuilding from them is always preferable to minting an ID that would
        // orphan an existing inbox and outbox tree.
        let anchored = anchoredProfileIDs(in: defaults)
        if !anchored.isEmpty {
            writeRoster(anchored, in: defaults)
            return anchored
        }

        if !defaults.bool(forKey: scopingMigrationKey) {
            let adopted = adoptPreScopingInstallation(in: defaults)
            defaults.set(true, forKey: scopingMigrationKey)
            writeRoster([adopted], in: defaults)
            return [adopted]
        }

        // Migration already ran and no profile survives it. This is a genuinely
        // empty installation, so a freshly minted profile orphans nothing.
        let minted = mintProfileID(in: defaults)
        writeRoster([minted], in: defaults)
        return [minted]
    }

    static func activeProfileID(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: activeProfileIDKey).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setActiveProfileID(_ profileID: String, in defaults: UserDefaults) {
        defaults.set(profileID, forKey: activeProfileIDKey)
    }

    /// Mints a new profile, appends it to the roster, and writes its anchor.
    static func appendProfileID(in defaults: UserDefaults) -> String {
        let minted = mintProfileID(in: defaults)
        var roster = storedRoster(in: defaults) ?? []
        roster.append(minted)
        writeRoster(roster, in: defaults)
        return minted
    }

    /// Drops a profile from the roster and erases its scoped values. The
    /// caller is responsible for erasing Keychain and on-disk storage FIRST —
    /// the connection ID that names those Keychain accounts lives in the
    /// scoped values this removes.
    static func removeProfileID(_ profileID: String, in defaults: UserDefaults) {
        var roster = storedRoster(in: defaults) ?? []
        roster.removeAll { $0 == profileID }
        writeRoster(roster, in: defaults)
        if activeProfileID(in: defaults) == profileID {
            defaults.removeObject(forKey: activeProfileIDKey)
        }
        ConnectionSettings.purgeScopedValues(profileID: profileID, in: defaults)
    }

    private static func storedRoster(in defaults: UserDefaults) -> [String]? {
        guard let raw = defaults.array(forKey: rosterKey) as? [String] else {
            return nil
        }
        let filtered = raw.filter { !$0.isEmpty }
        return filtered.isEmpty ? nil : filtered
    }

    private static func writeRoster(_ roster: [String], in defaults: UserDefaults) {
        defaults.set(roster, forKey: rosterKey)
    }

    /// Recovers profile IDs from the self-describing anchor each profile writes
    /// into its own scoped keyspace.
    private static func anchoredProfileIDs(in defaults: UserDefaults) -> [String] {
        defaults.dictionaryRepresentation().keys
            .compactMap(ConnectionSettings.profileID(fromAnchorKey:))
            .sorted()
    }

    private static func mintProfileID(in defaults: UserDefaults) -> String {
        let minted = UUID().uuidString
        ConnectionSettings.writeProfileAnchor(profileID: minted, in: defaults)
        return minted
    }

    /// Adopts an installation that predates profile-scoped storage.
    ///
    /// The adopted ID must equal what `ConnectionSettings` previously resolved,
    /// or the existing inbox archive, observation queue, API token, and identity
    /// pin all become unreachable. The precedence below reproduces the former
    /// resolution order exactly: connection ID first, then the profile ID that
    /// was seeded from it.
    private static func adoptPreScopingInstallation(in defaults: UserDefaults) -> String {
        let legacyConnectionID = nonEmpty(defaults.string(forKey: ConnectionSettings.legacyConnectionIDKey))
        let legacyProfileID = nonEmpty(defaults.string(forKey: ConnectionSettings.legacyProfileIDKey))

        let resolvedConnectionID = legacyConnectionID ?? UUID().uuidString
        let resolvedProfileID = legacyProfileID ?? resolvedConnectionID

        ConnectionSettings.adoptLegacyValues(
            profileID: resolvedProfileID,
            connectionID: resolvedConnectionID,
            in: defaults
        )
        return resolvedProfileID
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
