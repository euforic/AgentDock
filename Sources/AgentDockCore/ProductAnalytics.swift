import Foundation
import OSLog

public enum AnalyticsConsent: String, Sendable {
    case undecided
    case denied
    case granted
}

public struct AnalyticsConsentStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyDefaultsIfNeeded()
    }

    public var consent: AnalyticsConsent {
        guard let storedValue = defaults.string(forKey: Key.consent) else {
            return .undecided
        }
        return AnalyticsConsent(rawValue: storedValue) ?? .denied
    }

    public var installationID: UUID? {
        guard consent == .granted,
              let value = defaults.string(forKey: Key.installationID)
        else { return nil }
        return UUID(uuidString: value)
    }

    @discardableResult
    public func grant() -> UUID {
        let identifier = defaults.string(forKey: Key.installationID)
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString.lowercased(), forKey: Key.installationID)
        defaults.set(AnalyticsConsent.granted.rawValue, forKey: Key.consent)
        return identifier
    }

    public func denyAndDeleteIdentifier() {
        defaults.set(AnalyticsConsent.denied.rawValue, forKey: Key.consent)
        defaults.removeObject(forKey: Key.installationID)
    }

    public func resetDecisionAndDeleteIdentifier() {
        defaults.set(AnalyticsConsent.undecided.rawValue, forKey: Key.consent)
        defaults.removeObject(forKey: Key.installationID)
    }

    private func migrateLegacyDefaultsIfNeeded() {
        if defaults.string(forKey: Key.consent) == nil {
            let legacyValue = defaults.string(forKey: Key.legacyConsent)
            let migrated: AnalyticsConsent
            switch legacyValue {
            case AnalyticsConsent.denied.rawValue:
                migrated = .denied
            case AnalyticsConsent.granted.rawValue,
                 AnalyticsConsent.undecided.rawValue,
                 nil:
                // v1 was opt-out. Require an explicit choice before v2 sends data.
                migrated = .undecided
            default:
                migrated = .denied
            }
            defaults.set(migrated.rawValue, forKey: Key.consent)
        }
        // Keep older builds fail-closed after an upgrade and sever the old identifier.
        defaults.set(AnalyticsConsent.denied.rawValue, forKey: Key.legacyConsent)
        defaults.removeObject(forKey: Key.legacyInstallationID)
    }

    private enum Key {
        static let consent = "AgentDock.analyticsConsent.v2"
        static let installationID = "AgentDock.analyticsInstallationID.v2"
        static let legacyConsent = "AgentDock.analyticsConsent.v1"
        static let legacyInstallationID = "AgentDock.analyticsInstallationID.v1"
    }
}

public enum AnalyticsEventName: String, CaseIterable, Sendable {
    case appLifecycle = "app_lifecycle"
    case consentDecision = "consent_decision"
    case navigation = "navigation"
    case profileLifecycle = "profile_lifecycle"
    case providerStatus = "provider_status"
    case launcherLifecycle = "launcher_lifecycle"
    case chatUsage = "chat_usage"
    case refresh = "refresh"
    case updateLifecycle = "update_lifecycle"
    case preferenceChanged = "preference_changed"
    case error = "error"
    case performance = "performance"
    case featureAdoption = "feature_adoption"
    case profileInventory = "profile_inventory"
    case usageSnapshot = "usage_snapshot"
}

public enum AnalyticsSurface: String, CaseIterable, Sendable {
    case onboarding, sidebar, overview, chats, advanced, settingsGeneral, settingsProviders
    case settingsPrivacy, settingsAbout, menu, shortcut, updater
}

public enum AnalyticsAction: String, CaseIterable, Sendable {
    case launched, becameActive, consentGranted, consentDenied
    case viewed, searched, selected, created, restored, edited, removed, deleted
    case discovered, configured, validated, opened, focused, closed
    case installed, repaired, uninstalled
    case listed, transcriptOpened, transcriptPageLoaded, metadataViewed, metadataCopied
    case manualRefresh, automaticRefresh
    case updateChecked, updateAvailable, updateDownloadStarted, updateDownloaded
    case updateInstallStarted, updateCycleCompleted, updatePreferenceChanged
    case appearanceChanged, defaultViewChanged, activityRefreshChanged, statusVisibilityChanged
    case observed
}

public enum AnalyticsOutcome: String, CaseIterable, Sendable {
    case succeeded, failed, cancelled, unavailable, rejected, noChange
}

public enum AnalyticsProvider: String, CaseIterable, Sendable, Hashable {
    case codex, claude, mixed, none
}

public enum AnalyticsTrigger: String, CaseIterable, Sendable {
    case firstLaunch, user, automatic, applicationMenu, profileShortcut, settings
}

public enum AnalyticsFeature: String, CaseIterable, Sendable {
    case managedProfiles, officialApps, shortcuts, chats, transcriptPagination
    case localActivity, rateLimits, providerConfiguration, updates, privacyControls
}

public enum AnalyticsErrorCode: String, CaseIterable, Sendable {
    case storeUnavailable, persistenceFailed, providerNotFound, signatureRejected
    case launchFailed, closeFailed, shortcutFailed, transcriptUnavailable
    case refreshFailed, rateLimitUnavailable, updateUnavailable, invalidConfiguration
    case operationBusy, unknownSafe
}

public enum AnalyticsProfileScope: String, CaseIterable, Sendable, Hashable {
    case managed, official
}

public enum AnalyticsPlanTier: String, CaseIterable, Sendable, Hashable {
    case free, plus, pro, max, team, business, enterprise, education, unknown

    public init(providerValue: String?) {
        let normalized = providerValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "free": self = .free
        case "plus": self = .plus
        case "pro": self = .pro
        case "max", "max-5x", "max-20x": self = .max
        case "team", "teams": self = .team
        case "business": self = .business
        case "enterprise": self = .enterprise
        case "education", "edu": self = .education
        default: self = .unknown
        }
    }
}

public enum AnalyticsUsageBucket: String, CaseIterable, Sendable, Hashable {
    case zero, under25, percent25To49, percent50To74, percent75To89
    case percent90To99, atOrOver100

    public init(usedPercent: Double) {
        let value = usedPercent.isFinite ? max(0, usedPercent) : 0
        switch value {
        case 0: self = .zero
        case ..<25: self = .under25
        case ..<50: self = .percent25To49
        case ..<75: self = .percent50To74
        case ..<90: self = .percent75To89
        case ..<100: self = .percent90To99
        default: self = .atOrOver100
        }
    }
}

public enum AnalyticsLimitWindow: String, CaseIterable, Sendable, Hashable {
    case primary, secondary
}

public enum AnalyticsDurationBucket: String, CaseIterable, Sendable {
    case under100ms, ms100To499, ms500To1999, seconds2To9, seconds10Plus

    public init(milliseconds: Int) {
        switch max(0, milliseconds) {
        case ..<100: self = .under100ms
        case ..<500: self = .ms100To499
        case ..<2_000: self = .ms500To1999
        case ..<10_000: self = .seconds2To9
        default: self = .seconds10Plus
        }
    }
}

public enum AnalyticsCountBucket: String, CaseIterable, Sendable {
    case zero, one, twoToFive, sixToTwenty, twentyOnePlus

    public init(_ count: Int) {
        switch max(0, count) {
        case 0: self = .zero
        case 1: self = .one
        case 2...5: self = .twoToFive
        case 6...20: self = .sixToTwenty
        default: self = .twentyOnePlus
        }
    }
}

public enum AnalyticsPropertyKey: String, Sendable {
    case surface, action, outcome, provider, trigger, feature, errorCode
    case durationBucket, countBucket, enabled, profileScope, planTier, usageBucket, limitWindow
}

public enum AnalyticsProperty: Sendable {
    case surface(AnalyticsSurface)
    case action(AnalyticsAction)
    case outcome(AnalyticsOutcome)
    case provider(AnalyticsProvider)
    case trigger(AnalyticsTrigger)
    case feature(AnalyticsFeature)
    case errorCode(AnalyticsErrorCode)
    case durationBucket(AnalyticsDurationBucket)
    case countBucket(AnalyticsCountBucket)
    case enabled(Bool)
    case profileScope(AnalyticsProfileScope)
    case planTier(AnalyticsPlanTier)
    case usageBucket(AnalyticsUsageBucket)
    case limitWindow(AnalyticsLimitWindow)

    var key: AnalyticsPropertyKey {
        switch self {
        case .surface: .surface
        case .action: .action
        case .outcome: .outcome
        case .provider: .provider
        case .trigger: .trigger
        case .feature: .feature
        case .errorCode: .errorCode
        case .durationBucket: .durationBucket
        case .countBucket: .countBucket
        case .enabled: .enabled
        case .profileScope: .profileScope
        case .planTier: .planTier
        case .usageBucket: .usageBucket
        case .limitWindow: .limitWindow
        }
    }

    var jsonValue: Any {
        switch self {
        case let .surface(value): value.rawValue
        case let .action(value): value.rawValue
        case let .outcome(value): value.rawValue
        case let .provider(value): value.rawValue
        case let .trigger(value): value.rawValue
        case let .feature(value): value.rawValue
        case let .errorCode(value): value.rawValue
        case let .durationBucket(value): value.rawValue
        case let .countBucket(value): value.rawValue
        case let .enabled(value): value
        case let .profileScope(value): value.rawValue
        case let .planTier(value): value.rawValue
        case let .usageBucket(value): value.rawValue
        case let .limitWindow(value): value.rawValue
        }
    }
}

public struct AnalyticsEvent: Sendable {
    public let name: AnalyticsEventName
    public let properties: [AnalyticsProperty]

    public init?(_ name: AnalyticsEventName, _ properties: [AnalyticsProperty]) {
        let keys = properties.map(\.key)
        guard properties.count <= 8,
              Set(keys).count == keys.count,
              Set(keys).isSubset(of: name.allowedPropertyKeys),
              name.requiredPropertyKeys.isSubset(of: Set(keys))
        else { return nil }
        self.name = name
        self.properties = properties
    }
}

private extension AnalyticsEventName {
    var requiredPropertyKeys: Set<AnalyticsPropertyKey> {
        switch self {
        case .appLifecycle, .consentDecision, .navigation, .profileLifecycle,
             .providerStatus, .launcherLifecycle, .chatUsage, .refresh,
             .updateLifecycle, .preferenceChanged, .featureAdoption,
             .profileInventory, .usageSnapshot:
            [.action]
        case .error: [.errorCode]
        case .performance: [.durationBucket]
        }
    }

    var allowedPropertyKeys: Set<AnalyticsPropertyKey> {
        switch self {
        case .appLifecycle: [.action, .trigger, .countBucket]
        case .consentDecision: [.action, .surface]
        case .navigation: [.action, .surface, .provider]
        case .profileLifecycle: [.action, .outcome, .provider, .countBucket, .durationBucket]
        case .providerStatus: [.action, .outcome, .provider]
        case .launcherLifecycle: [.action, .outcome, .provider, .trigger, .durationBucket, .countBucket]
        case .chatUsage: [.action, .outcome, .provider, .countBucket, .durationBucket]
        case .refresh: [.action, .outcome, .surface, .trigger, .countBucket, .durationBucket]
        case .updateLifecycle: [.action, .outcome, .trigger, .enabled]
        case .preferenceChanged: [.action, .surface, .enabled]
        case .error: [.errorCode, .surface, .provider, .action]
        case .performance: [.durationBucket, .surface, .action, .provider, .countBucket]
        case .featureAdoption: [.action, .feature, .surface, .provider]
        case .profileInventory: [.action, .outcome, .provider, .profileScope, .planTier, .countBucket]
        case .usageSnapshot: [
            .action, .outcome, .provider, .profileScope, .planTier,
            .usageBucket, .limitWindow, .countBucket
        ]
        }
    }
}

public enum AnalyticsDeliveryFailure: String, Sendable, Equatable {
    case transport, invalidResponse, rejected, serialization
}

public struct AnalyticsDeliveryDiagnostics: Sendable, Equatable {
    public let successfulBatches: Int
    public let failedBatches: Int
    public let lastFailure: AnalyticsDeliveryFailure?
}

public struct ProductAnalyticsConfiguration: Equatable, Sendable {
    public let projectToken: String
    public let host: URL

    public init?(projectToken: String, host: String) {
        guard projectToken.range(
            of: #"^phc_[A-Za-z0-9_-]{8,128}$"#,
            options: .regularExpression
        ) != nil,
        var components = URLComponents(string: host),
        components.scheme == "https",
        components.host != nil,
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.path.isEmpty || components.path == "/",
        components.query == nil,
        components.fragment == nil
        else { return nil }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/batch/"
        guard let captureURL = components.url else { return nil }
        self.projectToken = projectToken
        self.host = captureURL
    }

    public init?(bundle: Bundle) {
        guard let token = bundle.object(forInfoDictionaryKey: "AgentDockPostHogProjectToken") as? String,
              let host = bundle.object(forInfoDictionaryKey: "AgentDockPostHogHost") as? String
        else { return nil }
        self.init(projectToken: token, host: host)
    }
}

public final class ProductAnalytics: @unchecked Sendable {
    public static let shared = ProductAnalytics()

    private let consentStore: AnalyticsConsentStore
    private let configuration: ProductAnalyticsConfiguration?
    private let session: URLSession
    private let appVersion: String
    private let osMajorVersion: Int
    private let architecture: String
    private let deliveryQueue = DispatchQueue(label: "dev.euforic.agentdock.analytics")
    private var pendingEvents: [AnalyticsEvent] = []
    private var activeTasks: [UUID: URLSessionDataTask] = [:]
    private var scheduledFlush: DispatchWorkItem?
    private var successfulBatches = 0
    private var failedBatches = 0
    private var lastDeliveryFailure: AnalyticsDeliveryFailure?
    private let logger = Logger(subsystem: "dev.euforic.agentdock", category: "ProductAnalytics")
    private static let flushAt = 12
    private static let maximumPendingEvents = 48
    private static let maximumActiveBatches = 1
    private static let flushDelay: TimeInterval = 5

    public init(
        consentStore: AnalyticsConsentStore = AnalyticsConsentStore(),
        configuration: ProductAnalyticsConfiguration? = ProductAnalyticsConfiguration(bundle: .main),
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
        osMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
        architecture: String = ProductAnalytics.currentArchitecture
    ) {
        self.consentStore = consentStore
        self.configuration = configuration
        self.appVersion = Self.safeVersion(appVersion)
        self.osMajorVersion = max(0, min(osMajorVersion, 999))
        self.architecture = ["arm64", "x86_64"].contains(architecture) ? architecture : "other"
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.timeoutIntervalForRequest = 10
        sessionConfiguration.timeoutIntervalForResource = 15
        sessionConfiguration.waitsForConnectivity = false
        self.session = URLSession(configuration: sessionConfiguration)
    }

    public var isConfigured: Bool { configuration != nil }
    public var consent: AnalyticsConsent { consentStore.consent }

    @discardableResult
    public func grantConsent(surface: AnalyticsSurface) -> UUID {
        let identifier = consentStore.grant()
        capture(AnalyticsEvent(.consentDecision, [.action(.consentGranted), .surface(surface)]))
        if surface == .onboarding {
            capture(AnalyticsEvent(.appLifecycle, [.action(.launched), .trigger(.firstLaunch)]))
        }
        return identifier
    }

    public func denyConsent() {
        consentStore.denyAndDeleteIdentifier()
        deliveryQueue.sync {
            scheduledFlush?.cancel()
            scheduledFlush = nil
            pendingEvents.removeAll(keepingCapacity: false)
            activeTasks.values.forEach { $0.cancel() }
            activeTasks.removeAll(keepingCapacity: false)
        }
    }

    public func capture(_ event: AnalyticsEvent?) {
        guard let event, payload(for: event) != nil else { return }
        deliveryQueue.async { [weak self] in
            guard let self, self.consentStore.consent == .granted else { return }
            if self.pendingEvents.count >= Self.maximumPendingEvents {
                self.pendingEvents.removeFirst()
            }
            self.pendingEvents.append(event)
            if self.pendingEvents.count >= Self.flushAt {
                self.flushLocked()
            } else if self.scheduledFlush == nil {
                let work = DispatchWorkItem { [weak self] in self?.flushLocked() }
                self.scheduledFlush = work
                self.deliveryQueue.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
            }
        }
    }

    func payload(for event: AnalyticsEvent) -> [String: Any]? {
        guard let configuration, consentStore.consent == .granted,
              let identifier = consentStore.installationID
        else { return nil }
        var properties: [String: Any] = [
            "token": configuration.projectToken,
            "distinct_id": identifier.uuidString.lowercased(),
            "$geoip_disable": true,
            "$process_person_profile": false,
            "schema_version": 1,
            "app_version": appVersion,
            "os_major": osMajorVersion,
            "architecture": architecture
        ]
        for property in event.properties {
            properties[property.key.rawValue] = property.jsonValue
        }
        return ["event": event.name.rawValue, "properties": properties]
    }

    func deliverySnapshot() -> (pending: Int, active: Int) {
        deliveryQueue.sync { (pendingEvents.count, activeTasks.count) }
    }

    public func deliveryDiagnostics() -> AnalyticsDeliveryDiagnostics {
        deliveryQueue.sync {
            AnalyticsDeliveryDiagnostics(
                successfulBatches: successfulBatches,
                failedBatches: failedBatches,
                lastFailure: lastDeliveryFailure
            )
        }
    }

    private func flushLocked() {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        scheduledFlush?.cancel()
        scheduledFlush = nil
        guard consentStore.consent == .granted, let configuration, !pendingEvents.isEmpty else {
            pendingEvents.removeAll(keepingCapacity: false)
            return
        }
        guard activeTasks.count < Self.maximumActiveBatches else {
            scheduleFlushLocked()
            return
        }
        let batch = pendingEvents.compactMap(payload(for:))
        pendingEvents.removeAll(keepingCapacity: true)
        guard !batch.isEmpty else { return }
        let body: [String: Any] = ["api_key": configuration.projectToken, "batch": batch]
        guard let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64 * 1_024 else {
            recordDeliveryFailure(.serialization)
            return
        }
        var request = URLRequest(url: configuration.host, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let deliveryID = UUID()
        let task = session.dataTask(with: request) { [weak self] _, response, error in
            self?.deliveryQueue.async { [weak self] in
                guard let self else { return }
                self.activeTasks.removeValue(forKey: deliveryID)
                if let failure = Self.deliveryFailure(response: response, error: error) {
                    self.recordDeliveryFailure(failure)
                } else {
                    self.successfulBatches += 1
                }
                if !self.pendingEvents.isEmpty {
                    self.flushLocked()
                }
            }
        }
        activeTasks[deliveryID] = task
        task.resume()
    }

    private func scheduleFlushLocked() {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        guard scheduledFlush == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushLocked() }
        scheduledFlush = work
        deliveryQueue.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
    }

    static func deliveryFailure(response: URLResponse?, error: Error?) -> AnalyticsDeliveryFailure? {
        if error != nil { return .transport }
        guard let response = response as? HTTPURLResponse else { return .invalidResponse }
        return (200..<300).contains(response.statusCode) ? nil : .rejected
    }

    private func recordDeliveryFailure(_ failure: AnalyticsDeliveryFailure) {
        dispatchPrecondition(condition: .onQueue(deliveryQueue))
        failedBatches += 1
        lastDeliveryFailure = failure
        logger.error("Analytics delivery failed: \(failure.rawValue, privacy: .public)")
    }

    private static func safeVersion(_ value: String) -> String {
        let permitted = value.prefix(32).filter { $0.isNumber || $0 == "." || $0 == "-" }
        return permitted.isEmpty ? "development" : String(permitted)
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }
}
