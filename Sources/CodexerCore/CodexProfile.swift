import Foundation

public enum DesktopProduct: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: Self { self }

    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    public var capabilities: DesktopProductCapabilities {
        switch self {
        case .codex:
            DesktopProductCapabilities(
                supportsUsageLimits: true,
                supportsActivityMetadata: true,
                supportsLocalChats: true,
                supportsOAuthCallbackPort: true
            )
        case .claude:
            DesktopProductCapabilities(
                supportsUsageLimits: true,
                supportsActivityMetadata: true,
                supportsLocalChats: true,
                supportsOAuthCallbackPort: false
            )
        }
    }
}

public struct DesktopProductCapabilities: Equatable, Sendable {
    public let supportsUsageLimits: Bool
    public let supportsActivityMetadata: Bool
    public let supportsLocalChats: Bool
    public let supportsOAuthCallbackPort: Bool
}

public enum ProfileIconKind: String, Codable, CaseIterable, Sendable {
    case monogram
    case symbol
    case image
}

public struct CodexProfile: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var product: DesktopProduct
    public var name: String
    public var slug: String
    public var profileDirectory: URL
    public var shortcutDirectory: URL
    public var shortcutFileName: String
    public var mcpOAuthCallbackPort: Int
    public var iconColor: String
    public var iconKind: ProfileIconKind
    public var iconValue: String
    public var codexLaunchProfileSelection: CodexLaunchProfileSelection
    public var codexDefaultConfigProfile: CodexConfigProfile?
    public var createdAt: Date
    public var lastLaunchedAt: Date?

    public var codexHomePath: URL {
        profileDirectory.appendingPathComponent("CODEX_HOME", isDirectory: true)
    }

    public var electronUserDataPath: URL {
        profileDirectory.appendingPathComponent("ElectronUserData", isDirectory: true)
    }

    public var claudeUserDataPath: URL {
        profileDirectory.appendingPathComponent("UserData", isDirectory: true)
    }

    public var managedDataPath: URL {
        switch product {
        case .codex: codexHomePath
        case .claude: claudeUserDataPath
        }
    }

    public var shortcutPath: URL {
        shortcutDirectory.appendingPathComponent(shortcutFileName, isDirectory: true)
    }

    public var customIconPath: URL {
        profileDirectory.appendingPathComponent("ProfileIcon.png")
    }

    public init(
        id: UUID = UUID(),
        product: DesktopProduct = .codex,
        name: String,
        slug: String,
        rootDirectory: URL,
        shortcutDirectory: URL? = nil,
        mcpOAuthCallbackPort: Int? = nil,
        iconColor: String = "#2563EB",
        iconKind: ProfileIconKind = .monogram,
        iconValue: String = "",
        codexLaunchProfileSelection: CodexLaunchProfileSelection = .useDefault,
        codexDefaultConfigProfile: CodexConfigProfile? = nil,
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        let profilesRoot = rootDirectory.appendingPathComponent("Profiles", isDirectory: true)
        let profileDirectory = switch product {
        case .codex:
            profilesRoot.appendingPathComponent(slug, isDirectory: true)
        case .claude:
            profilesRoot
                .appendingPathComponent(product.rawValue, isDirectory: true)
                .appendingPathComponent(slug, isDirectory: true)
        }
        let shortcutsRoot = shortcutDirectory ?? rootDirectory
            .appendingPathComponent("Shortcuts", isDirectory: true)
        let shortcutDirectory = product == .codex
            ? shortcutsRoot
            : shortcutsRoot.appendingPathComponent(product.rawValue, isDirectory: true)

        self.init(
            id: id,
            product: product,
            name: name,
            slug: slug,
            profileDirectory: profileDirectory,
            shortcutDirectory: shortcutDirectory,
            mcpOAuthCallbackPort: mcpOAuthCallbackPort,
            iconColor: iconColor,
            iconKind: iconKind,
            iconValue: iconValue,
            codexLaunchProfileSelection: codexLaunchProfileSelection,
            codexDefaultConfigProfile: codexDefaultConfigProfile,
            createdAt: createdAt,
            lastLaunchedAt: lastLaunchedAt
        )
    }

    public init(
        id: UUID = UUID(),
        product: DesktopProduct = .codex,
        name: String,
        slug: String,
        profileDirectory: URL,
        shortcutDirectory: URL,
        mcpOAuthCallbackPort: Int? = nil,
        iconColor: String = "#2563EB",
        iconKind: ProfileIconKind = .monogram,
        iconValue: String = "",
        codexLaunchProfileSelection: CodexLaunchProfileSelection = .useDefault,
        codexDefaultConfigProfile: CodexConfigProfile? = nil,
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.product = product
        self.name = name
        self.slug = slug
        self.profileDirectory = profileDirectory
        self.shortcutDirectory = shortcutDirectory
        self.shortcutFileName = shortcutBundleName(name: name, slug: slug)
        self.mcpOAuthCallbackPort = product == .codex ? (mcpOAuthCallbackPort ?? 0) : 0
        self.iconColor = iconColor
        self.iconKind = iconKind
        self.iconValue = iconValue
        self.codexLaunchProfileSelection = product == .codex
            ? codexLaunchProfileSelection
            : .builtIn
        self.codexDefaultConfigProfile = product == .codex
            ? codexDefaultConfigProfile
            : nil
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case product
        case name
        case slug
        case profileDirectory
        case shortcutDirectory
        case shortcutFileName
        case codexHomePath
        case electronUserDataPath
        case shortcutPath
        case mcpOAuthCallbackPort
        case iconColor
        case iconKind
        case iconValue
        case codexLaunchProfileSelection
        case codexDefaultConfigProfile
        case createdAt
        case lastLaunchedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        product = try container.decodeIfPresent(DesktopProduct.self, forKey: .product) ?? .codex
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decode(String.self, forKey: .slug)
        iconColor = try container.decode(String.self, forKey: .iconColor)
        iconKind = try container.decodeIfPresent(ProfileIconKind.self, forKey: .iconKind) ?? .monogram
        iconValue = try container.decodeIfPresent(String.self, forKey: .iconValue) ?? ""
        codexLaunchProfileSelection = product == .codex
            ? (try container.decodeIfPresent(
                CodexLaunchProfileSelection.self,
                forKey: .codexLaunchProfileSelection
            ) ?? .useDefault)
            : .builtIn
        codexDefaultConfigProfile = product == .codex
            ? try container.decodeIfPresent(
                CodexConfigProfile.self,
                forKey: .codexDefaultConfigProfile
            )
            : nil
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
        mcpOAuthCallbackPort = product == .codex
            ? (try container.decodeIfPresent(Int.self, forKey: .mcpOAuthCallbackPort) ?? 0)
            : 0

        if let storedProfileDirectory = try container.decodeIfPresent(URL.self, forKey: .profileDirectory) {
            profileDirectory = storedProfileDirectory
        } else {
            let legacyCodexHome = try container.decode(URL.self, forKey: .codexHomePath)
            profileDirectory = legacyCodexHome.deletingLastPathComponent()
        }

        if let storedShortcutDirectory = try container.decodeIfPresent(URL.self, forKey: .shortcutDirectory) {
            shortcutDirectory = storedShortcutDirectory
            shortcutFileName = try container.decodeIfPresent(String.self, forKey: .shortcutFileName)
                ?? shortcutBundleName(name: name, slug: slug)
        } else {
            let legacyShortcutPath = try container.decode(URL.self, forKey: .shortcutPath)
            shortcutDirectory = legacyShortcutPath.deletingLastPathComponent()
            shortcutFileName = legacyShortcutPath.lastPathComponent
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(product, forKey: .product)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(profileDirectory, forKey: .profileDirectory)
        try container.encode(shortcutDirectory, forKey: .shortcutDirectory)
        try container.encode(shortcutFileName, forKey: .shortcutFileName)
        try container.encode(mcpOAuthCallbackPort, forKey: .mcpOAuthCallbackPort)
        try container.encode(iconColor, forKey: .iconColor)
        try container.encode(iconKind, forKey: .iconKind)
        try container.encode(iconValue, forKey: .iconValue)
        if product == .codex {
            try container.encode(codexLaunchProfileSelection, forKey: .codexLaunchProfileSelection)
            try container.encodeIfPresent(
                codexDefaultConfigProfile,
                forKey: .codexDefaultConfigProfile
            )
        }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
    }
}

public enum ProfileRemovalPolicy: String, Codable, CaseIterable, Sendable {
    case removeFromList
    case deleteAllData
}

public func slugify(_ value: String) -> String {
    let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    let scalars = folded.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar).lowercased()) : "-"
    }
    let collapsed = String(scalars)
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
    return collapsed.isEmpty ? "profile" : collapsed
}

public func shortcutBundleName(name _: String, slug: String) -> String {
    "\(slugify(slug)).app"
}

public func shortcutDisplayName(name: String, slug: String) -> String {
    let suffix = slug.split(separator: "-").last.flatMap { Int($0) }
    if let suffix, suffix > 1 {
        return "\(name) \(suffix)"
    }
    return name
}
