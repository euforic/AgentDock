import Foundation

public struct CodexConfigProfile: Codable, Hashable, Identifiable, RawRepresentable, Sendable {
    public let rawValue: String

    public var id: String { rawValue }
    public var name: String { rawValue }
    public var displayName: String {
        rawValue.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(validating name: String) throws {
        guard Self.isValidName(name) else {
            throw CodexConfigProfileError.invalidName(name)
        }
        rawValue = name
    }

    public func configurationURL(in codexHomeURL: URL) -> URL {
        codexHomeURL.appendingPathComponent("\(rawValue).config.toml", isDirectory: false)
    }

    public func validate(in codexHomeURL: URL) throws {
        guard Self.isValidName(rawValue) else {
            throw CodexConfigProfileError.invalidName(rawValue)
        }
        let url = configurationURL(in: codexHomeURL)
        do {
            _ = try BoundedFileReader.data(
                at: url,
                maximumBytes: LocalControlFileLimit.providerConfiguration
            )
        } catch {
            throw CodexConfigProfileError.unavailable(url.path)
        }
    }

    func appServerConfigOverrides(in codexHomeURL: URL) throws -> [String] {
        try validate(in: codexHomeURL)
        let url = configurationURL(in: codexHomeURL)
        let data: Data
        do {
            data = try BoundedFileReader.data(
                at: url,
                maximumBytes: LocalControlFileLimit.providerConfiguration
            )
        } catch {
            throw CodexConfigProfileError.unavailable(url.path)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw CodexConfigProfileError.invalidEncoding(url.path)
        }
        return try CodexConfigOverrideParser.parse(content)
    }

    public static func discover(in codexHomeURL: URL) -> [CodexConfigProfile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: codexHomeURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var profiles: [CodexConfigProfile] = []
        var inspectedCount = 0
        while inspectedCount < 256, let url = enumerator.nextObject() as? URL {
            inspectedCount += 1
            let suffix = ".config.toml"
            guard url.lastPathComponent.hasSuffix(suffix) else { continue }
            let name = String(url.lastPathComponent.dropLast(suffix.count))
            guard let profile = try? CodexConfigProfile(validating: name),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  (try? profile.validate(in: codexHomeURL)) != nil
            else {
                continue
            }
            profiles.append(profile)
        }
        return profiles.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48 ... 57, 65 ... 90, 97 ... 122, 45, 95:
                true
            default:
                false
            }
        }
    }
}

public enum CodexLaunchProfileSelection: Codable, Hashable, Sendable {
    case useDefault
    case builtIn
    case named(CodexConfigProfile)
}

public enum CodexConfigProfileError: Error, LocalizedError, Equatable {
    case invalidName(String)
    case unavailable(String)
    case invalidEncoding(String)
    case malformedConfiguration
    case unsupportedArrayTable
    case tooManySettings
    case sensitiveSetting(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(name):
            "The Codex profile name is invalid: \(name)"
        case let .unavailable(path):
            "The Codex profile configuration is missing or unsafe at \(path)."
        case let .invalidEncoding(path):
            "The Codex profile configuration is not valid UTF-8 at \(path)."
        case .malformedConfiguration:
            "The Codex profile configuration contains an incomplete TOML statement."
        case .unsupportedArrayTable:
            "The Codex profile configuration uses an array-of-tables section that the desktop launcher cannot apply safely."
        case .tooManySettings:
            "The Codex profile configuration contains too many settings."
        case let .sensitiveSetting(key):
            "The Codex profile setting \(key) cannot be passed safely to the desktop app-server. Use an environment-backed credential setting instead."
        }
    }
}

private enum CodexConfigOverrideParser {
    private enum StringMode {
        case basic
        case literal
        case multilineBasic
        case multilineLiteral
    }

    static func parse(_ content: String) throws -> [String] {
        let characters = Array(content)
        var index = 0
        var statement = ""
        var table = ""
        var overrides: [String] = []
        var stringMode: StringMode?
        var escaped = false
        var squareDepth = 0
        var curlyDepth = 0

        func hasTripleQuote(_ quote: Character, at offset: Int) -> Bool {
            offset + 2 < characters.count
                && characters[offset] == quote
                && characters[offset + 1] == quote
                && characters[offset + 2] == quote
        }

        func assignmentIndex(in value: String) -> String.Index? {
            var quote: Character?
            var escaped = false
            for position in value.indices {
                let character = value[position]
                if escaped {
                    escaped = false
                    continue
                }
                if character == "\\", quote == "\"" {
                    escaped = true
                    continue
                }
                if character == "\"" || character == "'" {
                    quote = quote == nil ? character : (quote == character ? nil : quote)
                    continue
                }
                if character == "=", quote == nil {
                    return position
                }
            }
            return nil
        }

        func flushStatement() throws {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            statement = ""
            guard !trimmed.isEmpty else { return }
            if trimmed.hasPrefix("[[") {
                throw CodexConfigProfileError.unsupportedArrayTable
            }
            if trimmed.hasPrefix("[") {
                guard trimmed.hasSuffix("]") else {
                    throw CodexConfigProfileError.malformedConfiguration
                }
                table = String(trimmed.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !table.isEmpty else {
                    throw CodexConfigProfileError.malformedConfiguration
                }
                return
            }
            guard let equals = assignmentIndex(in: trimmed) else {
                throw CodexConfigProfileError.malformedConfiguration
            }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty,
                  !key.contains("\n"), !key.contains("\0")
            else {
                throw CodexConfigProfileError.malformedConfiguration
            }
            guard overrides.count < 256 else {
                throw CodexConfigProfileError.tooManySettings
            }
            let path = table.isEmpty ? key : "\(table).\(key)"
            let normalizedPath = path.lowercased()
                .replacingOccurrences(of: "-", with: "_")
            let exposesSecret = normalizedPath.contains("bearer_token")
                || normalizedPath.contains("api_key")
                || (normalizedPath.contains("http_headers")
                    && !normalizedPath.contains("env_http_headers"))
            guard !exposesSecret else {
                throw CodexConfigProfileError.sensitiveSetting(path)
            }
            overrides.append("\(path)=\(value)")
        }

        while index < characters.count {
            let character = characters[index]
            if let mode = stringMode {
                if mode == .basic {
                    statement.append(character)
                    if escaped {
                        escaped = false
                    } else if character == "\\" {
                        escaped = true
                    } else if character == "\"" {
                        stringMode = nil
                    }
                    index += 1
                    continue
                }
                if mode == .literal {
                    statement.append(character)
                    if character == "'" {
                        stringMode = nil
                    }
                    index += 1
                    continue
                }
                let quote: Character = mode == .multilineBasic ? "\"" : "'"
                if hasTripleQuote(quote, at: index) {
                    statement.append(String(repeating: String(quote), count: 3))
                    stringMode = nil
                    index += 3
                } else {
                    statement.append(character)
                    index += 1
                }
                continue
            }

            if character == "#" {
                while index < characters.count, characters[index] != "\n" {
                    index += 1
                }
                continue
            }
            if character == "\"" || character == "'" {
                if hasTripleQuote(character, at: index) {
                    statement.append(String(repeating: String(character), count: 3))
                    stringMode = character == "\"" ? .multilineBasic : .multilineLiteral
                    index += 3
                } else {
                    statement.append(character)
                    stringMode = character == "\"" ? .basic : .literal
                    index += 1
                }
                continue
            }
            switch character {
            case "[":
                squareDepth += 1
                statement.append(character)
            case "]":
                squareDepth -= 1
                guard squareDepth >= 0 else {
                    throw CodexConfigProfileError.malformedConfiguration
                }
                statement.append(character)
            case "{":
                curlyDepth += 1
                statement.append(character)
            case "}":
                curlyDepth -= 1
                guard curlyDepth >= 0 else {
                    throw CodexConfigProfileError.malformedConfiguration
                }
                statement.append(character)
            case "\n":
                if squareDepth == 0, curlyDepth == 0 {
                    try flushStatement()
                } else {
                    statement.append(character)
                }
            default:
                statement.append(character)
            }
            index += 1
        }

        guard stringMode == nil, squareDepth == 0, curlyDepth == 0 else {
            throw CodexConfigProfileError.malformedConfiguration
        }
        try flushStatement()
        return overrides
    }
}
