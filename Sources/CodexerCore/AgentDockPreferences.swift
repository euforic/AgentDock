import Foundation

public enum AgentDockAppearance: String, Codable, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var displayName: String {
        rawValue.capitalized
    }
}

public enum AgentDockDefaultView: String, Codable, CaseIterable, Sendable {
    case home
    case lastOpened
    case overview

    public var displayName: String {
        switch self {
        case .home: "Home"
        case .lastOpened: "Last Opened Profile"
        case .overview: "Overview"
        }
    }
}

public struct AgentDockPreferences: Equatable, Sendable {
    public var appearance: AgentDockAppearance
    public var defaultView: AgentDockDefaultView
    public var refreshProfileActivity: Bool
    public var refreshIntervalMinutes: Int
    public var showStatusInProfileList: Bool

    public static let defaults = AgentDockPreferences(
        appearance: .system,
        defaultView: .home,
        refreshProfileActivity: true,
        refreshIntervalMinutes: 5,
        showStatusInProfileList: true
    )
}

public struct OfficialCodexProfileSettings: Equatable, Sendable {
    public var launchSelection: CodexLaunchProfileSelection
    public var defaultConfigProfile: CodexConfigProfile?

    public init(
        launchSelection: CodexLaunchProfileSelection = .useDefault,
        defaultConfigProfile: CodexConfigProfile? = nil
    ) {
        self.launchSelection = launchSelection
        self.defaultConfigProfile = defaultConfigProfile
    }

    public static let defaults = OfficialCodexProfileSettings()
}

public struct AgentDockPreferencesStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AgentDockPreferences {
        let standard = AgentDockPreferences.defaults
        let appearance = defaults.string(forKey: Key.appearance)
            .flatMap(AgentDockAppearance.init(rawValue:)) ?? standard.appearance
        let storedDefaultView = defaults.string(forKey: Key.defaultView)
        let defaultView: AgentDockDefaultView
        if storedDefaultView == "chats" {
            defaultView = .overview
            defaults.set(defaultView.rawValue, forKey: Key.defaultView)
        } else {
            defaultView = storedDefaultView.flatMap(AgentDockDefaultView.init(rawValue:))
                ?? standard.defaultView
        }
        let refresh = defaults.object(forKey: Key.refreshProfileActivity) == nil
            ? standard.refreshProfileActivity
            : defaults.bool(forKey: Key.refreshProfileActivity)
        let storedInterval = defaults.integer(forKey: Key.refreshIntervalMinutes)
        let interval = Self.allowedIntervals.contains(storedInterval)
            ? storedInterval
            : standard.refreshIntervalMinutes
        let showStatus = defaults.object(forKey: Key.showStatusInProfileList) == nil
            ? standard.showStatusInProfileList
            : defaults.bool(forKey: Key.showStatusInProfileList)
        return AgentDockPreferences(
            appearance: appearance,
            defaultView: defaultView,
            refreshProfileActivity: refresh,
            refreshIntervalMinutes: interval,
            showStatusInProfileList: showStatus
        )
    }

    public func save(_ preferences: AgentDockPreferences) {
        defaults.set(preferences.appearance.rawValue, forKey: Key.appearance)
        defaults.set(preferences.defaultView.rawValue, forKey: Key.defaultView)
        defaults.set(preferences.refreshProfileActivity, forKey: Key.refreshProfileActivity)
        defaults.set(
            Self.allowedIntervals.contains(preferences.refreshIntervalMinutes)
                ? preferences.refreshIntervalMinutes
                : AgentDockPreferences.defaults.refreshIntervalMinutes,
            forKey: Key.refreshIntervalMinutes
        )
        defaults.set(preferences.showStatusInProfileList, forKey: Key.showStatusInProfileList)
    }

    public func restoreDefaults() {
        [
            Key.appearance,
            Key.defaultView,
            Key.refreshProfileActivity,
            Key.refreshIntervalMinutes,
            Key.showStatusInProfileList,
            Key.officialCodexLaunchSelectionKind,
            Key.officialCodexLaunchSelectionName,
            Key.officialCodexDefaultConfigProfile,
            Key.legacyDefaultCodexConfigProfile
        ].forEach(defaults.removeObject(forKey:))
    }

    public func loadOfficialCodexProfileSettings() -> OfficialCodexProfileSettings {
        let defaultConfigProfile = defaults.string(forKey: Key.officialCodexDefaultConfigProfile)
            .flatMap { try? CodexConfigProfile(validating: $0) }
        let launchSelection: CodexLaunchProfileSelection
        switch defaults.string(forKey: Key.officialCodexLaunchSelectionKind) {
        case "builtIn":
            launchSelection = .builtIn
        case "named":
            launchSelection = defaults.string(forKey: Key.officialCodexLaunchSelectionName)
                .flatMap { try? CodexConfigProfile(validating: $0) }
                .map(CodexLaunchProfileSelection.named) ?? .useDefault
        default:
            launchSelection = .useDefault
        }
        return OfficialCodexProfileSettings(
            launchSelection: launchSelection,
            defaultConfigProfile: defaultConfigProfile
        )
    }

    public func saveOfficialCodexProfileSettings(_ settings: OfficialCodexProfileSettings) {
        switch settings.launchSelection {
        case .useDefault:
            defaults.removeObject(forKey: Key.officialCodexLaunchSelectionKind)
            defaults.removeObject(forKey: Key.officialCodexLaunchSelectionName)
        case .builtIn:
            defaults.set("builtIn", forKey: Key.officialCodexLaunchSelectionKind)
            defaults.removeObject(forKey: Key.officialCodexLaunchSelectionName)
        case let .named(configProfile):
            defaults.set("named", forKey: Key.officialCodexLaunchSelectionKind)
            defaults.set(configProfile.name, forKey: Key.officialCodexLaunchSelectionName)
        }
        defaults.set(
            settings.defaultConfigProfile?.name,
            forKey: Key.officialCodexDefaultConfigProfile
        )
    }

    public func legacyDefaultCodexConfigProfile() -> CodexConfigProfile? {
        defaults.string(forKey: Key.legacyDefaultCodexConfigProfile)
            .flatMap { try? CodexConfigProfile(validating: $0) }
    }

    public func clearLegacyDefaultCodexConfigProfile() {
        defaults.removeObject(forKey: Key.legacyDefaultCodexConfigProfile)
    }

    public static let allowedIntervals = [1, 5, 15, 30, 60]

    private enum Key {
        static let appearance = "AgentDock.appearance"
        static let defaultView = "AgentDock.defaultView"
        static let refreshProfileActivity = "AgentDock.refreshProfileActivity"
        static let refreshIntervalMinutes = "AgentDock.refreshIntervalMinutes"
        static let showStatusInProfileList = "AgentDock.showStatusInProfileList"
        static let officialCodexLaunchSelectionKind = "AgentDock.officialCodex.launchSelectionKind"
        static let officialCodexLaunchSelectionName = "AgentDock.officialCodex.launchSelectionName"
        static let officialCodexDefaultConfigProfile = "AgentDock.officialCodex.defaultConfigProfile"
        static let legacyDefaultCodexConfigProfile = "AgentDock.defaultCodexConfigProfile"
    }
}
