import Darwin
import Foundation
import Security

/// The only legacy brand spellings used by the runtime. Keep these for upgrades
/// and detached profiles created by releases predating the AgentDock name.
enum LegacyBrand {
    static let directoryName = "Codexer"
    static let ownershipFile = ".codexer-profile.json"
    static let lockDirectory = ".codexer-locks"
    static let deletionPrefix = ".codexer-deleting-"
    static let managementMarker = "# Codexer MCP OAuth isolation v1"
    static let preferencesDomain = "dev.euforic.codexer"
    static let preferencesPrefix = "Codexer."

    static func ownershipURL(in directory: URL) -> URL {
        let current = directory.appendingPathComponent(".agentdock-profile.json")
        let legacy = directory.appendingPathComponent(ownershipFile)
        return !exists(current) && exists(legacy) ? legacy : current
    }

    static func exists(_ url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0
    }

    static func migratePreferences(defaults: UserDefaults = .standard) {
        let marker = "AgentDock.brandPreferencesMigrated.v1"
        guard !defaults.bool(forKey: marker) else { return }
        let oldDomain = defaults.persistentDomain(forName: preferencesDomain) ?? [:]
        let values = oldDomain.merging(defaults.dictionaryRepresentation()) { _, current in current }
        for key in values.keys.sorted(by: { lhs, rhs in
            if lhs.hasSuffix(".codexAppPath") != rhs.hasSuffix(".codexAppPath") {
                return !lhs.hasSuffix(".codexAppPath")
            }
            return lhs < rhs
        }) where key.hasPrefix(preferencesPrefix) || key.hasPrefix("AgentDock.") {
            guard let value = values[key] else { continue }
            var destination = key.hasPrefix(preferencesPrefix)
                ? "AgentDock." + key.dropFirst(preferencesPrefix.count) : key
            if destination == "AgentDock.codexAppPath" { destination = "AgentDock.desktopAppPath.codex" }
            if defaults.object(forKey: destination) == nil { defaults.set(value, forKey: destination) }
        }
        defaults.set(true, forKey: marker)
    }
}

/// Moves whole directories on the same volume. A bounded, fixed-location journal
/// lets the next launch finish after either rename or the metadata commit. It
/// creates verified recovery copies before changing data, never follows profile
/// symlinks, and never merges stores.
enum LegacyBrandMigration {
    static let indexArchiveDirectoryName = "AgentDock Legacy Index Archives"

    struct Journal: Codable {
        var version = 1
        let moveRoot: Bool
        let moveShortcuts: Bool
        var backupID: UUID? = nil
    }

    static func migrate(applicationSupport: URL, applications: URL, keychain: SecKeychain? = nil) throws {
        let fm = FileManager.default
        let root = applicationSupport.appendingPathComponent("AgentDock", isDirectory: true)
        let oldRoot = applicationSupport.appendingPathComponent(LegacyBrand.directoryName, isDirectory: true)
        let shortcuts = applications.appendingPathComponent("AgentDock", isDirectory: true)
        let oldShortcuts = applications.appendingPathComponent(LegacyBrand.directoryName, isDirectory: true)
        let journalURL = applicationSupport.appendingPathComponent(".agentdock-brand-migration-v1.json")
        let completed = root.appendingPathComponent(".brand-migration-v1-complete")
        // A fresh installation does not create any legacy directories or journals.
        let needsMarkerMigration = try !LegacyBrand.exists(completed) && containsLegacyOwnership(in: root)
        guard LegacyBrand.exists(journalURL) || needsMarkerMigration
            || LegacyBrand.exists(oldRoot) || LegacyBrand.exists(oldShortcuts) else { return }
        try validateDirectory(applicationSupport)
        let lock = try AdvisoryFileLock.acquireSynchronously(
            at: applicationSupport.appendingPathComponent(".agentdock-brand-migration.lock")
        )
        defer { withExtendedLifetime(lock) {} }
        if LegacyBrand.exists(completed), !LegacyBrand.exists(journalURL) {
            try validateDirectory(root)
            guard try BoundedFileReader.data(at: completed, maximumBytes: 32) == Data("1\n".utf8) else {
                throw MigrationError.invalidJournal
            }
            return
        }
        // Desktop manager processes operate on the default store only. Isolated
        // fixture/custom roots still receive all file-use and profile-lock checks.
        if applicationSupport.standardizedFileURL.path == FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].standardizedFileURL.path {
            try requireOtherManagersClosed()
        }
        var journal: Journal
        let resuming = LegacyBrand.exists(journalURL)
        if resuming {
            journal = try JSONDecoder().decode(Journal.self, from: BoundedFileReader.data(
                at: journalURL, maximumBytes: 1_024
            ))
            guard journal.version == 1 else { throw MigrationError.invalidJournal }
        } else {
            journal = Journal(moveRoot: LegacyBrand.exists(oldRoot), moveShortcuts: LegacyBrand.exists(oldShortcuts))
        }
        for (source, destination, moving) in [(oldRoot, root, journal.moveRoot), (oldShortcuts, shortcuts, journal.moveShortcuts)] where moving {
            if LegacyBrand.exists(source) {
                try validateDirectory(source)
                if LegacyBrand.exists(destination) {
                    try validateDirectory(destination)
                    if try fm.contentsOfDirectory(atPath: destination.path).isEmpty {
                        try fm.removeItem(at: destination)
                    } else {
                        // Older builds wrote derived chat indexes under the new
                        // brand name before moving the actual Codexer store.
                        guard source == oldRoot, destination == root,
                              try archiveIndexOnlyDestination(root, applicationSupport: applicationSupport) else {
                            throw MigrationError.conflictingFolders
                        }
                    }
                }
            } else {
                guard resuming, LegacyBrand.exists(destination) else { throw MigrationError.invalidJournal }
                try validateDirectory(destination)
            }
        }
        let activeRoot = journal.moveRoot && LegacyBrand.exists(oldRoot) ? oldRoot : root
        let activeShortcuts = journal.moveShortcuts && LegacyBrand.exists(oldShortcuts) ? oldShortcuts : shortcuts
        if LegacyBrand.exists(activeRoot) { try validateDirectory(activeRoot) }
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        try validateDirectory(applications)
        if LegacyBrand.exists(activeShortcuts) { try validateDirectory(activeShortcuts) }
        // Check the whole tree, including profiles removed from the list and helpers
        // that no longer carry an Electron user-data argument.
        if LegacyBrand.exists(activeRoot) { try requireIdle(activeRoot) }
        let storeLock = try AdvisoryFileLock.acquireSynchronously(at: activeRoot.appendingPathComponent(".profiles.lock"))
        defer { withExtendedLifetime(storeLock) {} }
        var profileLocks: [ProfileOperationLock] = []
        var directoriesToLock = Set<String>()
        let profilesRoot = activeRoot.appendingPathComponent("Profiles")
        for parent in [profilesRoot, profilesRoot.appendingPathComponent("claude")] where LegacyBrand.exists(parent) {
            try validateDirectory(parent)
            for directory in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                if directory.path == profilesRoot.appendingPathComponent("claude").path { continue }
                guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { continue }
                try validateDirectory(directory)
                directoriesToLock.insert(directory.path)
            }
        }
        // A pending deletion may have quarantined a registered profile. Lock its
        // original path too, before recovery can make it launchable again.
        let sourceMetadata = activeRoot.appendingPathComponent("profiles.json")
        if LegacyBrand.exists(sourceMetadata) {
            let profiles = try JSONDecoder.agentdock.decode([CodexProfile].self, from: BoundedFileReader.data(
                at: sourceMetadata, maximumBytes: LocalControlFileLimit.profiles
            ))
            for profile in profiles {
                guard !profile.slug.isEmpty, profile.slug != ".", profile.slug != "..",
                      profile.slug == URL(fileURLWithPath: profile.slug).lastPathComponent else {
                    throw MigrationError.invalidJournal
                }
                let parent = profile.product == .codex ? profilesRoot : profilesRoot.appendingPathComponent("claude")
                directoriesToLock.insert(parent.appendingPathComponent(profile.slug).path)
            }
        }
        var lockedPaths = Set<String>()
        for directory in directoriesToLock.sorted() {
            let url = URL(fileURLWithPath: directory)
            let lockPath = ProfileOperationLock.lockFileURL(for: url).path
            guard lockedPaths.insert(lockPath).inserted else { continue }
            profileLocks.append(try ProfileOperationLock.acquireSynchronously(for: url))
        }
        defer { withExtendedLifetime(profileLocks) {} }
        try requireIdle(activeRoot)
        try removeStaleCodexSockets(in: profilesRoot)
        if let backupID = journal.backupID {
            try MigrationBackup.verify(applicationSupport: applicationSupport, id: backupID)
        } else {
            journal.backupID = try MigrationBackup.create(
                applicationSupport: applicationSupport, store: activeRoot, shortcuts: activeShortcuts
            )
            // Existing older journals are upgraded before any further mutations.
            if resuming {
                try MigrationBackup.durableWrite(JSONEncoder().encode(journal), to: journalURL)
            }
        }
        if !resuming {
            // Recover existing store journals and enforce the normal ownership/layout
            // checks before recording migration intent, using the locks held above.
            try ProfileStore.prepareForBrandMigration(root: activeRoot, shortcuts: activeShortcuts)
        }
        if journal.moveRoot, LegacyBrand.exists(profilesRoot) {
            for directory in try fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                let home = directory.appendingPathComponent("CODEX_HOME")
                guard LegacyBrand.exists(home) else { continue }
                try validateDirectory(directory)
                try validateDirectory(home)
                // Detached profiles are preserved too; only a correctly bound marker
                // allows us to migrate their path-derived credential entries.
                struct Marker: Decodable { let profileID: UUID; let slug: String; let product: DesktopProduct? }
                let marker = try JSONDecoder().decode(Marker.self, from: BoundedFileReader.data(
                    at: LegacyBrand.ownershipURL(in: directory), maximumBytes: LocalControlFileLimit.ownershipMarker
                ))
                guard marker.slug == directory.lastPathComponent, marker.product == nil || marker.product == .codex else {
                    throw MigrationError.invalidJournal
                }
                try ProfileCredentialMigration.migrate(
                    oldHome: oldRoot.appendingPathComponent("Profiles").appendingPathComponent(marker.slug).appendingPathComponent("CODEX_HOME"),
                    newHome: root.appendingPathComponent("Profiles").appendingPathComponent(marker.slug).appendingPathComponent("CODEX_HOME"),
                    existingHome: home, keychain: keychain
                )
            }
        }
        if !resuming { try MigrationBackup.durableWrite(JSONEncoder().encode(journal), to: journalURL) }
        if journal.moveRoot, LegacyBrand.exists(oldRoot) {
            try fm.moveItem(at: oldRoot, to: root)
            try MigrationBackup.syncDirectory(applicationSupport)
        }
        if journal.moveShortcuts, LegacyBrand.exists(oldShortcuts) {
            try fm.moveItem(at: oldShortcuts, to: shortcuts)
            try MigrationBackup.syncDirectory(applications)
        }
        try fm.createDirectory(at: shortcuts, withIntermediateDirectories: true)
        let profilesURL = root.appendingPathComponent("profiles.json")
        if LegacyBrand.exists(profilesURL) {
            var profiles = try JSONDecoder.agentdock.decode([CodexProfile].self, from: BoundedFileReader.data(
                at: profilesURL, maximumBytes: LocalControlFileLimit.profiles
            ))
            for index in profiles.indices {
                let profile = profiles[index]
                let relative = profile.product == .codex ? "Profiles" : "Profiles/claude"
                let expected = root.appendingPathComponent(relative).appendingPathComponent(profile.slug)
                let legacy = oldRoot.appendingPathComponent(relative).appendingPathComponent(profile.slug)
                guard !profile.slug.isEmpty, profile.slug == URL(fileURLWithPath: profile.slug).lastPathComponent,
                      profile.profileDirectory.standardizedFileURL.path == expected.standardizedFileURL.path
                        || (journal.moveRoot && profile.profileDirectory.standardizedFileURL.path == legacy.standardizedFileURL.path)
                else { throw MigrationError.invalidJournal }
                let destination = profile.product == .codex ? shortcuts : shortcuts.appendingPathComponent("claude")
                let source = profile.product == .codex ? oldShortcuts : oldShortcuts.appendingPathComponent("claude")
                guard profile.shortcutDirectory.standardizedFileURL.path == destination.standardizedFileURL.path
                    || (journal.moveShortcuts && profile.shortcutDirectory.standardizedFileURL.path == source.standardizedFileURL.path)
                else { throw MigrationError.invalidJournal }
                profiles[index].profileDirectory = expected
                profiles[index].shortcutDirectory = destination
            }
            try MigrationBackup.durableWrite(JSONEncoder.agentdock.encode(profiles), to: profilesURL)
        }
        // Revalidate at the final location before marking the migration complete.
        try ProfileStore.prepareForBrandMigration(root: root, shortcuts: shortcuts, finalize: true)
        try MigrationBackup.durableWrite(Data("1\n".utf8), to: completed)
        try fm.removeItem(at: journalURL)
        try MigrationBackup.syncDirectory(applicationSupport)
    }

    private static func containsLegacyOwnership(in root: URL) throws -> Bool {
        guard LegacyBrand.exists(root) else { return false }
        try validateDirectory(root)
        let metadata = root.appendingPathComponent("profiles.json")
        guard LegacyBrand.exists(metadata) else { return false }
        let profiles = try JSONDecoder.agentdock.decode([CodexProfile].self, from: BoundedFileReader.data(
            at: metadata, maximumBytes: LocalControlFileLimit.profiles
        ))
        for profile in profiles {
            guard !profile.slug.isEmpty, profile.slug != ".", profile.slug != "..",
                  profile.slug == URL(fileURLWithPath: profile.slug).lastPathComponent else {
                throw MigrationError.invalidJournal
            }
            let directory = root.appendingPathComponent(profile.product == .codex ? "Profiles" : "Profiles/claude")
                .appendingPathComponent(profile.slug)
            guard LegacyBrand.exists(directory) else { continue }
            try validateDirectory(directory)
            if LegacyBrand.exists(directory.appendingPathComponent(LegacyBrand.ownershipFile)) { return true }
        }
        return false
    }

    private static func validateDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid(),
              url.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.path
        else { throw MigrationError.unsafeFolder }
    }

    /// The old chat index is a cache, but preserve its entire directory tree.
    /// An atomic rename also makes an interrupted attempt safe to retry.
    private static func archiveIndexOnlyDestination(_ root: URL, applicationSupport: URL) throws -> Bool {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        guard let indexes = entries.first(where: { $0.lastPathComponent == "ChatIndexes" }),
              entries.allSatisfy({ $0 == indexes || $0.lastPathComponent == ".DS_Store" }) else { return false }
        try validateDirectory(indexes)
        try requireIdle(root)
        let parent = applicationSupport.appendingPathComponent(indexArchiveDirectoryName, isDirectory: true)
        if !LegacyBrand.exists(parent) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try validateDirectory(parent)
        var status = stat()
        guard lstat(parent.path, &status) == 0, status.st_mode & 0o077 == 0 else {
            throw MigrationError.unsafeFolder
        }
        try fm.moveItem(at: root, to: parent.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try MigrationBackup.syncDirectory(parent)
        try MigrationBackup.syncDirectory(applicationSupport)
        return true
    }

    /// Codex leaves Unix socket nodes behind after some exits. They contain no
    /// persistent state and cannot be copied by the verified recovery backup.
    /// Touch only the known IPC path after all profile locks and idle checks.
    private static func removeStaleCodexSockets(in profilesRoot: URL) throws {
        guard LegacyBrand.exists(profilesRoot) else { return }
        try validateDirectory(profilesRoot)
        let fm = FileManager.default
        for profile in try fm.contentsOfDirectory(at: profilesRoot, includingPropertiesForKeys: nil) {
            if profile.lastPathComponent == "claude" { continue }
            var profileStatus = stat()
            guard lstat(profile.path, &profileStatus) == 0, profileStatus.st_mode & S_IFMT == S_IFDIR else { continue }
            try validateDirectory(profile)
            let home = profile.appendingPathComponent("CODEX_HOME", isDirectory: true)
            guard LegacyBrand.exists(home) else { continue }
            try validateDirectory(home)
            let ipc = home.appendingPathComponent("ipc", isDirectory: true)
            guard LegacyBrand.exists(ipc) else { continue }
            try validateDirectory(ipc)
            let path = ipc.appendingPathComponent("ipc.sock")
            var before = stat()
            guard lstat(path.path, &before) == 0, before.st_mode & S_IFMT == S_IFSOCK else { continue }
            guard before.st_uid == geteuid() else { throw MigrationError.inUse }
            try requireSocketUnreferenced(at: path)
            var after = stat()
            guard lstat(path.path, &after) == 0, before.st_dev == after.st_dev,
                  before.st_ino == after.st_ino, after.st_mode & S_IFMT == S_IFSOCK else {
                throw MigrationError.inUse
            }
            let quarantine = ipc.appendingPathComponent(".agentdock-stale-ipc-\(UUID().uuidString)")
            guard rename(path.path, quarantine.path) == 0 else { throw MigrationError.inUse }
            var moved = stat()
            guard lstat(quarantine.path, &moved) == 0, moved.st_dev == before.st_dev,
                  moved.st_ino == before.st_ino, moved.st_mode & S_IFMT == S_IFSOCK else {
                // A replacement is never deleted. Restore it when the original
                // path is free; otherwise leave the quarantine for inspection.
                if !LegacyBrand.exists(path) { _ = rename(quarantine.path, path.path) }
                throw MigrationError.inUse
            }
            guard unlink(quarantine.path) == 0 else {
                if !LegacyBrand.exists(path) { _ = rename(quarantine.path, path.path) }
                throw MigrationError.inUse
            }
            try MigrationBackup.syncDirectory(ipc)
        }
    }

    static func requireSocketUnreferenced(at url: URL) throws {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-t", url.path],
            timeout: 3, maximumOutputBytes: 1_024 * 1_024, captureStandardError: true
        )
        guard result.terminationStatus == 1, result.output.isEmpty, !result.exceededOutputLimit else {
            throw MigrationError.inUse
        }
    }

    private static func requireOtherManagersClosed() throws {
        let result = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"), arguments: ["-ax", "-o", "pid=", "-o", "comm="],
            timeout: 3, maximumOutputBytes: 8 * 1_024 * 1_024
        )
        guard result.terminationStatus == 0, !result.exceededOutputLimit else { throw MigrationError.inUse }
        for line in String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, let pid = Int32(fields[0]), pid != getpid() else { continue }
            let executable = URL(fileURLWithPath: fields[1].trimmingCharacters(in: .whitespaces)).lastPathComponent
            if executable == LegacyBrand.directoryName || executable == "AgentDock" { throw MigrationError.inUse }
        }
    }

    private static func requireIdle(_ root: URL) throws {
        let files = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/usr/sbin/lsof"), arguments: ["-t", "+D", root.path],
            timeout: 10, maximumOutputBytes: 1_024 * 1_024, captureStandardError: true
        )
        let openFilePIDs = String(decoding: files.output, as: UTF8.self).split(whereSeparator: \.isNewline)
        guard (files.terminationStatus == 0 || files.terminationStatus == 1), !files.exceededOutputLimit,
              openFilePIDs.allSatisfy({ Int32($0) == getpid() }) else {
            throw MigrationError.inUse
        }
        let processes = try BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/ps"), arguments: ["-ax", "-o", "command="],
            timeout: 3, maximumOutputBytes: 8 * 1_024 * 1_024
        )
        guard processes.terminationStatus == 0, !processes.exceededOutputLimit,
              !String(decoding: processes.output, as: UTF8.self).contains(root.path) else {
            throw MigrationError.inUse
        }
    }

    enum MigrationError: Error, LocalizedError {
        case conflictingFolders, invalidJournal, unsafeFolder, inUse
        var errorDescription: String? {
            switch self {
            case .conflictingFolders:
                "Both legacy and AgentDock folders contain data. Migration stopped without merging them. Preserve both folders and resolve the conflict before relaunching."
            case .invalidJournal:
                "The AgentDock migration metadata could not be validated. Your profile data has been preserved."
            case .unsafeFolder:
                "AgentDock cannot migrate a linked folder or a folder owned by another user."
            case .inUse:
                "Close the previous profile manager and all managed provider apps, then relaunch AgentDock to finish migrating your profiles."
            }
        }
    }
}
