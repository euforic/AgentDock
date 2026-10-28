import CryptoKit
import Darwin
import Foundation

/// Recovery copies are never automatically removed. A receipt is published only
/// after every source and copied tree matches and copied files reach the disk.
enum MigrationBackup {
    static let directoryName = "AgentDock Migration Backups"

    private struct Receipt: Codable {
        let version: Int
        let storeDigest: String?
        let shortcutsDigest: String?
    }

    static func create(applicationSupport: URL, store: URL, shortcuts: URL) throws -> UUID {
        let fm = FileManager.default
        let parent = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        if !LegacyBrand.exists(parent) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try validateContainer(parent)
        let id = UUID()
        let destination = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // On failure retain partial copies too. No recovery data is deleted to
        // make room, and a later attempt receives a different UUID.
        let storeDigest = try copyAndVerify(store, to: destination.appendingPathComponent("Store"))
        let shortcutsDigest = try copyAndVerify(shortcuts, to: destination.appendingPathComponent("Shortcuts"))
        let receipt = Receipt(version: 1, storeDigest: storeDigest, shortcutsDigest: shortcutsDigest)
        try durableWrite(JSONEncoder().encode(receipt), to: destination.appendingPathComponent("receipt.json"))
        try syncDirectory(parent)
        return id
    }

    static func verify(applicationSupport: URL, id: UUID) throws {
        let parent = applicationSupport.appendingPathComponent(directoryName, isDirectory: true)
        try validateContainer(parent)
        let backup = parent.appendingPathComponent(id.uuidString, isDirectory: true)
        try validateContainer(backup)
        let receipt = try JSONDecoder().decode(Receipt.self, from: BoundedFileReader.data(
            at: backup.appendingPathComponent("receipt.json"), maximumBytes: 4_096
        ))
        guard receipt.version == 1 else { throw BackupError.invalidBackup }
        for (name, expected) in [("Store", receipt.storeDigest), ("Shortcuts", receipt.shortcutsDigest)] {
            let tree = backup.appendingPathComponent(name)
            if let expected {
                guard try digest(tree) == expected else { throw BackupError.invalidBackup }
            } else if LegacyBrand.exists(tree) {
                throw BackupError.invalidBackup
            }
        }
    }

    private static func copyAndVerify(_ source: URL, to destination: URL) throws -> String? {
        guard LegacyBrand.exists(source) else { return nil }
        let before = try digest(source)
        try FileManager.default.copyItem(at: source, to: destination)
        guard try digest(destination, syncFiles: true) == before,
              try digest(source) == before else { throw BackupError.sourceChanged }
        return before
    }

    /// No link traversal, no whole-file buffers, and no special-file opens. The
    /// tree hash includes names, types, permissions, file bytes and link targets.
    static func digest(_ root: URL, syncFiles: Bool = false) throws -> String {
        var hash = SHA256()
        try appendNode(root, name: "", hash: &hash, syncFiles: syncFiles, depth: 0)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func appendNode(_ url: URL, name: String, hash: inout SHA256, syncFiles: Bool, depth: Int) throws {
        try Task.checkCancellation()
        guard depth < 256 else { throw BackupError.unsupportedFile }
        let before = try status(url)
        append(name, to: &hash)
        append(String(before.st_mode), to: &hash)
        switch before.st_mode & S_IFMT {
        case S_IFDIR:
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            append(String(children.count), to: &hash)
            for child in children {
                try appendNode(child, name: child.lastPathComponent, hash: &hash, syncFiles: syncFiles, depth: depth + 1)
            }
            if syncFiles { try syncDirectory(url) }
        case S_IFLNK:
            append(try FileManager.default.destinationOfSymbolicLink(atPath: url.path), to: &hash)
        case S_IFREG:
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw BackupError.unsupportedFile }
            defer { close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, unchanged(before, opened) else { throw BackupError.sourceChanged }
            var content = SHA256()
            var buffer = [UInt8](repeating: 0, count: 128 * 1_024)
            var total: off_t = 0
            while true {
                try Task.checkCancellation()
                let count = read(descriptor, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw BackupError.unsupportedFile }
                if count == 0 { break }
                total += off_t(count)
                guard total <= before.st_size else { throw BackupError.sourceChanged }
                content.update(data: Data(buffer.prefix(count)))
            }
            guard total == before.st_size else { throw BackupError.sourceChanged }
            hash.update(data: Data(content.finalize()))
            if syncFiles, fsync(descriptor) != 0 { throw BackupError.syncFailed }
        default:
            throw BackupError.unsupportedFile
        }
        guard unchanged(before, try status(url)) else { throw BackupError.sourceChanged }
    }

    private static func append(_ value: String, to hash: inout SHA256) {
        let bytes = Data(value.utf8)
        hash.update(data: Data("\(bytes.count):".utf8))
        hash.update(data: bytes)
    }

    private static func status(_ url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw BackupError.unsupportedFile }
        return result
    }

    private static func unchanged(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func validateContainer(_ url: URL) throws {
        let info = try status(url)
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              url.standardizedFileURL.path == url.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw BackupError.invalidBackup
        }
    }

    static func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupError.syncFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0, fcntl(descriptor, F_FULLFSYNC) == 0 else { throw BackupError.syncFailed }
        try syncDirectory(url.deletingLastPathComponent())
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw BackupError.syncFailed }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw BackupError.syncFailed }
    }

    enum BackupError: Error, LocalizedError {
        case invalidBackup, sourceChanged, unsupportedFile, syncFailed
        var errorDescription: String? {
            switch self {
            case .invalidBackup:
                "The migration recovery backup could not be verified. Migration stopped and existing data was preserved."
            case .sourceChanged:
                "Profile data changed while its recovery backup was being verified. Close managed apps and retry; existing data was preserved."
            case .unsupportedFile:
                "A profile file could not be safely backed up. Migration stopped and existing data was preserved."
            case .syncFailed:
                "The migration recovery data could not be saved durably. Check available disk space and retry; existing data was preserved."
            }
        }
    }
}
