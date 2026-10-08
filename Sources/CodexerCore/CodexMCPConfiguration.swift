import Darwin
import Foundation

public enum CodexMCPConfiguration {
    public static let managedCallbackPorts = 49_152...65_535
    public static let managementMarker = "# Codexer MCP OAuth isolation v1"

    public static func configure(
        codexHomeURL: URL,
        callbackPort: Int,
        codexAppURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        try validatePort(callbackPort)
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        let existed = fileManager.fileExists(atPath: configURL.path)
        let originalData = existed
            ? try BoundedFileReader.data(
                at: configURL,
                maximumBytes: LocalControlFileLimit.providerConfiguration
            )
            : nil
        let existing = try readConfig(at: configURL, fileManager: fileManager) ?? ""
        let existingPermissions = existed
            ? (try fileManager.attributesOfItem(atPath: configURL.path)[.posixPermissions] as? NSNumber)?.uint16Value
            : nil
        let updated = try configuredContent(existing, callbackPort: callbackPort)
        guard updated != existing else { return }

        let temporaryURL = codexHomeURL
            .appendingPathComponent(".config.toml.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try Data(updated.utf8).write(to: temporaryURL, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: existingPermissions ?? 0o600)],
            ofItemAtPath: temporaryURL.path
        )
        if fileManager.fileExists(atPath: configURL.path) {
            _ = try fileManager.replaceItemAt(configURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: configURL)
        }
        do {
            try validate(
                codexHomeURL: codexHomeURL,
                expectedCallbackPort: callbackPort,
                fileManager: fileManager
            )
            if let codexAppURL {
                try validateWithBundledCodex(
                    codexAppURL: codexAppURL,
                    codexHomeURL: codexHomeURL
                )
            }
        } catch {
            do {
                if existed, let originalData {
                    try originalData.write(to: configURL, options: .atomic)
                    if let existingPermissions {
                        try fileManager.setAttributes(
                            [.posixPermissions: NSNumber(value: existingPermissions)],
                            ofItemAtPath: configURL.path
                        )
                    }
                } else if fileManager.fileExists(atPath: configURL.path) {
                    try fileManager.removeItem(at: configURL)
                }
            } catch {
                throw CodexMCPConfigurationError.rollbackFailed(configURL.path)
            }
            throw error
        }
    }

    public static func validate(
        codexHomeURL: URL,
        expectedCallbackPort: Int? = nil,
        fileManager: FileManager = .default
    ) throws {
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        guard let content = try readConfig(at: configURL, fileManager: fileManager) else {
            throw CodexMCPConfigurationError.missingConfig(configURL.path)
        }
        let result = try scan(content)
        guard result.hasManagementMarker else {
            throw CodexMCPConfigurationError.unmanagedConfig(configURL.path)
        }
        guard let rawPort = result.callbackPortValue,
              let callbackPort = Int(stripInlineComment(rawPort).trimmingCharacters(in: .whitespaces)),
              managedCallbackPorts.contains(callbackPort)
        else {
            throw CodexMCPConfigurationError.invalidCallbackPort(configURL.path)
        }
        if let expectedCallbackPort, callbackPort != expectedCallbackPort {
            throw CodexMCPConfigurationError.unexpectedCallbackPort(
                expected: expectedCallbackPort,
                actual: callbackPort
            )
        }
        guard let rawStore = result.credentialsStoreValue,
              unquote(stripInlineComment(rawStore).trimmingCharacters(in: .whitespaces)) == "keyring"
        else {
            throw CodexMCPConfigurationError.invalidCredentialsStore(configURL.path)
        }
        guard let rawFeature = result.secretAuthStorageValue,
              stripInlineComment(rawFeature).trimmingCharacters(in: .whitespaces) == "true"
        else {
            throw CodexMCPConfigurationError.secretAuthStorageDisabled(configURL.path)
        }
    }

    public static func isManaged(
        codexHomeURL: URL,
        fileManager: FileManager = .default
    ) throws -> Bool {
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        guard let content = try readConfig(at: configURL, fileManager: fileManager) else {
            return false
        }
        return try scan(content).hasManagementMarker
    }

    public static func existingCallbackPort(
        codexHomeURL: URL,
        fileManager: FileManager = .default
    ) throws -> Int? {
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        guard let content = try readConfig(at: configURL, fileManager: fileManager) else {
            return nil
        }
        let result = try scan(content)
        guard let rawPort = result.callbackPortValue,
              let port = Int(stripInlineComment(rawPort).trimmingCharacters(in: .whitespaces)),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    public static func isAvailableForBinding(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fileDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { return false }
        defer { close(fileDescriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fileDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    public static func validateWithBundledCodex(
        codexAppURL: URL,
        codexHomeURL: URL
    ) throws {
        let executableURL = CodexBundledCLI.executableURL(for: codexAppURL)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw CodexMCPConfigurationError.missingCodexExecutable(
                executableURL.path
            )
        }
        let validationHomeURL = try makeIsolatedValidationHome(
            codexHomeURL: codexHomeURL
        )
        defer { try? FileManager.default.removeItem(at: validationHomeURL) }
        let result = try BoundedSubprocess.run(
            executableURL: executableURL,
            arguments: ["features", "list"],
            timeout: 5,
            maximumOutputBytes: 512 * 1_024,
            captureStandardError: true,
            environmentOverrides: ["CODEX_HOME": validationHomeURL.path]
        )
        let output = String(decoding: result.output, as: UTF8.self)
        guard result.terminationStatus == 0,
              !result.exceededOutputLimit,
              output.split(whereSeparator: \.isNewline).contains(where: { line in
                  let fields = line.split(whereSeparator: \.isWhitespace)
                  return fields.first == "secret_auth_storage"
                      && fields.last == "true"
              })
        else {
            throw CodexMCPConfigurationError.bundledCodexRejectedConfig(
                codexHomeURL.appendingPathComponent("config.toml").path
            )
        }
    }

    static func makeIsolatedValidationHome(
        codexHomeURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let configURL = codexHomeURL.appendingPathComponent("config.toml")
        let validationHomeURL = fileManager.temporaryDirectory
            .appendingPathComponent(
                "AgentDockCodexConfigProbe-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try fileManager.createDirectory(
                at: validationHomeURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            try fileManager.createSymbolicLink(
                at: validationHomeURL.appendingPathComponent("config.toml"),
                withDestinationURL: configURL
            )
            return validationHomeURL
        } catch {
            try? fileManager.removeItem(at: validationHomeURL)
            throw error
        }
    }

    public static func configuredContent(
        _ existing: String,
        callbackPort: Int
    ) throws -> String {
        try validatePort(callbackPort)
        let separator = existing.contains("\r\n") ? "\r\n" : "\n"
        let preserveFinalSeparator = existing.isEmpty || existing.hasSuffix(separator)
        var lines = existing.isEmpty ? [] : existing.components(separatedBy: separator)
        var result = try scan(lines)

        if let line = result.callbackPortLine {
            lines[line] = "mcp_oauth_callback_port = \(callbackPort)"
        }
        if let line = result.credentialsStoreLine {
            lines[line] = #"mcp_oauth_credentials_store = "keyring""#
        }

        var prefix: [String] = []
        if !result.hasManagementMarker {
            prefix.append(managementMarker)
        }
        if result.callbackPortLine == nil {
            prefix.append("mcp_oauth_callback_port = \(callbackPort)")
        }
        if result.credentialsStoreLine == nil {
            prefix.append(#"mcp_oauth_credentials_store = "keyring""#)
        }
        if !prefix.isEmpty {
            prefix.append("")
            lines.insert(contentsOf: prefix, at: 0)
        }

        result = try scan(lines)
        if let line = result.secretAuthStorageLine {
            lines[line] = result.secretAuthStorageUsesDottedKey
                ? "features.secret_auth_storage = true"
                : "secret_auth_storage = true"
        } else if let insertionIndex = result.featuresTableEndLine {
            lines.insert("secret_auth_storage = true", at: insertionIndex)
        } else if result.hasDottedFeaturesKey {
            lines.insert("features.secret_auth_storage = true", at: 0)
        } else {
            while lines.last?.isEmpty == true {
                lines.removeLast()
            }
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("[features]")
            lines.append("secret_auth_storage = true")
        }

        var updated = lines.joined(separator: separator)
        if preserveFinalSeparator, !updated.hasSuffix(separator) {
            updated.append(separator)
        }
        return updated
    }

    private struct ScanResult {
        var callbackPortLine: Int?
        var callbackPortValue: String?
        var credentialsStoreLine: Int?
        var credentialsStoreValue: String?
        var featuresTableEndLine: Int?
        var hasDottedFeaturesKey = false
        var hasManagementMarker = false
        var secretAuthStorageLine: Int?
        var secretAuthStorageUsesDottedKey = false
        var secretAuthStorageValue: String?
    }

    private static func scan(_ content: String) throws -> ScanResult {
        let separator = content.contains("\r\n") ? "\r\n" : "\n"
        return try scan(content.components(separatedBy: separator))
    }

    private static func scan(_ lines: [String]) throws -> ScanResult {
        var result = ScanResult()
        var currentTable: String?
        var multilineDelimiter: String?

        for (index, line) in lines.enumerated() {
            if let delimiter = multilineDelimiter {
                if delimiterOccurrenceCount(in: line, delimiter: delimiter).isMultiple(of: 2) == false {
                    multilineDelimiter = nil
                }
                continue
            }

            let trimmedOriginal = line.trimmingCharacters(in: .whitespaces)
            if trimmedOriginal == managementMarker {
                result.hasManagementMarker = true
                continue
            }

            let visible = stripInlineComment(line)
            let trimmed = visible.trimmingCharacters(in: .whitespaces)
            if let delimiter = startingMultilineDelimiter(in: visible) {
                multilineDelimiter = delimiter
            }

            if trimmed.hasPrefix("["),
               trimmed.hasSuffix("]"),
               !trimmed.hasPrefix("[[")
            {
                if currentTable == "features", result.featuresTableEndLine == nil {
                    result.featuresTableEndLine = index
                }
                currentTable = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                continue
            }

            guard !trimmed.isEmpty,
                  let separator = visible.firstIndex(of: "=")
            else {
                continue
            }
            let key = visible[..<separator].trimmingCharacters(in: .whitespaces)
            let value = String(visible[visible.index(after: separator)...])
            if key.hasPrefix(#"""#), key.hasSuffix(#"""#) {
                let unquotedKey = String(key.dropFirst().dropLast())
                if [
                    "mcp_oauth_callback_port",
                    "mcp_oauth_credentials_store",
                    "features.secret_auth_storage",
                    "secret_auth_storage"
                ].contains(unquotedKey) {
                    throw CodexMCPConfigurationError.ambiguousManagedKey(
                        unquotedKey
                    )
                }
            }

            if currentTable == nil {
                if key.hasPrefix("features.") {
                    result.hasDottedFeaturesKey = true
                }
                switch key {
                case "mcp_oauth_callback_port":
                    try record(
                        key: key,
                        line: index,
                        value: value,
                        existingLine: &result.callbackPortLine,
                        existingValue: &result.callbackPortValue
                    )
                case "mcp_oauth_credentials_store":
                    try record(
                        key: key,
                        line: index,
                        value: value,
                        existingLine: &result.credentialsStoreLine,
                        existingValue: &result.credentialsStoreValue
                    )
                case "features.secret_auth_storage":
                    try recordSecretAuthStorage(
                        line: index,
                        value: value,
                        usesDottedKey: true,
                        result: &result
                    )
                default:
                    break
                }
            } else if currentTable == "features", key == "secret_auth_storage" {
                try recordSecretAuthStorage(
                    line: index,
                    value: value,
                    usesDottedKey: false,
                    result: &result
                )
            }
        }
        if currentTable == "features", result.featuresTableEndLine == nil {
            result.featuresTableEndLine = lines.count
        }
        return result
    }

    private static func record(
        key: String,
        line: Int,
        value: String,
        existingLine: inout Int?,
        existingValue: inout String?
    ) throws {
        guard existingLine == nil else {
            throw CodexMCPConfigurationError.duplicateTopLevelKey(key)
        }
        existingLine = line
        existingValue = value
    }

    private static func recordSecretAuthStorage(
        line: Int,
        value: String,
        usesDottedKey: Bool,
        result: inout ScanResult
    ) throws {
        guard result.secretAuthStorageLine == nil else {
            throw CodexMCPConfigurationError.duplicateTopLevelKey(
                "features.secret_auth_storage"
            )
        }
        result.secretAuthStorageLine = line
        result.secretAuthStorageValue = value
        result.secretAuthStorageUsesDottedKey = usesDottedKey
    }

    private static func readConfig(
        at configURL: URL,
        fileManager: FileManager
    ) throws -> String? {
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }
        let data: Data
        do {
            data = try BoundedFileReader.data(
                at: configURL,
                maximumBytes: LocalControlFileLimit.providerConfiguration
            )
        } catch {
            throw CodexMCPConfigurationError.unsafeConfig(configURL.path)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw CodexMCPConfigurationError.invalidEncoding(configURL.path)
        }
        return content
    }

    private static func validatePort(_ port: Int) throws {
        guard managedCallbackPorts.contains(port) else {
            throw CodexMCPConfigurationError.invalidCallbackPort(String(port))
        }
    }

    private static func startingMultilineDelimiter(in line: String) -> String? {
        for delimiter in [#"""""#, "'''"] where
            delimiterOccurrenceCount(in: line, delimiter: delimiter).isMultiple(of: 2) == false
        {
            return delimiter
        }
        return nil
    }

    private static func delimiterOccurrenceCount(
        in value: String,
        delimiter: String
    ) -> Int {
        value.components(separatedBy: delimiter).count - 1
    }

    private static func stripInlineComment(_ value: String) -> String {
        var quote: Character?
        for index in value.indices {
            let character = value[index]
            if character == #"""# || character == "'" {
                quote = quote == nil ? character : (quote == character ? nil : quote)
            } else if character == "#", quote == nil {
                return String(value[..<index])
            }
        }
        return value
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == #"""# && last == #"""#) || (first == "'" && last == "'")
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }
}

public enum CodexMCPConfigurationError: Error, LocalizedError, Equatable {
    case ambiguousManagedKey(String)
    case bundledCodexRejectedConfig(String)
    case duplicateTopLevelKey(String)
    case invalidCallbackPort(String)
    case invalidCredentialsStore(String)
    case invalidEncoding(String)
    case missingConfig(String)
    case missingCodexExecutable(String)
    case rollbackFailed(String)
    case secretAuthStorageDisabled(String)
    case unexpectedCallbackPort(expected: Int, actual: Int)
    case unsafeConfig(String)
    case unmanagedConfig(String)

    public var errorDescription: String? {
        switch self {
        case let .ambiguousManagedKey(key):
            "Codex config uses unsupported quoted syntax for managed key \(key)."
        case let .bundledCodexRejectedConfig(path):
            "The selected Codex app rejected the profile config at \(path)."
        case let .duplicateTopLevelKey(key):
            "Codex config contains more than one \(key) setting."
        case let .invalidCallbackPort(path):
            "Codex MCP OAuth callback port is invalid in \(path)."
        case let .invalidCredentialsStore(path):
            "Codex MCP OAuth credentials store must be keyring in \(path)."
        case let .invalidEncoding(path):
            "Codex config is not valid UTF-8 at \(path)."
        case let .missingConfig(path):
            "Codex config is missing at \(path)."
        case let .missingCodexExecutable(path):
            "The selected Codex app does not contain an executable at \(path)."
        case let .rollbackFailed(path):
            "AgentDock could not roll back a failed config update at \(path)."
        case let .secretAuthStorageDisabled(path):
            "Profile-scoped encrypted MCP OAuth storage is not enabled in \(path)."
        case let .unexpectedCallbackPort(expected, actual):
            "Codex MCP OAuth callback port changed from \(expected) to \(actual)."
        case let .unsafeConfig(path):
            "Codex config must be a regular file and cannot be a symbolic link at \(path)."
        case let .unmanagedConfig(path):
            "Codex MCP OAuth isolation has not been configured at \(path)."
        }
    }
}
