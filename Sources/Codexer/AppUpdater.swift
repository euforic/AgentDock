import Combine
import Foundation
import CodexerCore
import Sparkle

enum AppUpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case alpha

    static let preferenceKey = "AgentDockUpdateChannel"
    static let stableFeedURL = "https://gh.euforic.one/AgentDock/appcast.xml"
    static let alphaFeedURL = "https://gh.euforic.one/AgentDock/appcast-alpha.xml"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stable: "Stable"
        case .alpha: "Alpha"
        }
    }

    var feedURL: String {
        switch self {
        case .stable: Self.stableFeedURL
        case .alpha: Self.alphaFeedURL
        }
    }

    static func saved(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .stable
    }
}

enum AppUpdateCheckFrequency: TimeInterval, CaseIterable, Identifiable {
    case hourly = 3_600
    case everySixHours = 21_600
    case daily = 86_400
    case weekly = 604_800

    var id: TimeInterval { rawValue }

    var displayName: String {
        switch self {
        case .hourly: "Hourly"
        case .everySixHours: "Every 6 Hours"
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }

    static func closest(to interval: TimeInterval) -> Self {
        allCases.min { lhs, rhs in
            abs(lhs.rawValue - interval) < abs(rhs.rawValue - interval)
        } ?? .hourly
    }
}

enum AppUpdatePresentation: Equatable {
    case hidden
    case available(version: String)
    case presenting(version: String)
    case downloading(version: String)
    case preparingInstallation(version: String)
    case installing(version: String)
    case failed(version: String)

    var isVisible: Bool {
        self != .hidden
    }

    var showsProgress: Bool {
        switch self {
        case .downloading, .preparingInstallation, .installing:
            true
        case .hidden, .available, .presenting, .failed:
            false
        }
    }

    var usesCompactAvailableStyle: Bool {
        switch self {
        case .available, .presenting:
            true
        case .hidden, .downloading, .preparingInstallation, .installing, .failed:
            false
        }
    }

    var allowsAction: Bool {
        switch self {
        case .available, .failed:
            true
        case .hidden, .presenting, .downloading, .preparingInstallation, .installing:
            false
        }
    }

    var buttonTitle: String {
        switch self {
        case .hidden:
            ""
        case .available:
            "Update"
        case .presenting:
            "Update"
        case .downloading:
            "Downloading…"
        case .preparingInstallation:
            "Preparing…"
        case .installing:
            "Installing…"
        case .failed:
            "Try Again"
        }
    }

    var version: String? {
        switch self {
        case .hidden:
            nil
        case let .available(version), let .presenting(version), let .downloading(version),
             let .preparingInstallation(version), let .installing(version), let .failed(version):
            version
        }
    }

    func completingUpdateCycle(hadError: Bool) -> AppUpdatePresentation {
        switch self {
        case .hidden:
            .hidden
        case let .available(version), let .presenting(version), let .downloading(version),
             let .preparingInstallation(version):
            hadError ? .failed(version: version) : .available(version: version)
        case .installing, .failed:
            self
        }
    }

    func keepingCompact(whileStandardWindowIsActive isActive: Bool) -> AppUpdatePresentation {
        guard isActive, let version else { return self }
        return .presenting(version: version)
    }
}

@MainActor
private final class AppUpdateUserDriver: SPUStandardUserDriver {
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?
    private var installsNextUpdate = false
    private var installsWithoutWindow = false

    func installAvailableUpdate() -> Bool {
        guard let reply = pendingInstallReply else {
            installsNextUpdate = true
            installsWithoutWindow = true
            return false
        }
        pendingInstallReply = nil
        installsWithoutWindow = true
        reply(.install)
        return true
    }

    override func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        if installsNextUpdate, !appcastItem.isInformationOnlyUpdate {
            installsNextUpdate = false
            reply(.install)
            return
        }
        installsNextUpdate = false
        guard !state.userInitiated else {
            installsWithoutWindow = false
            super.showUpdateFound(with: appcastItem, state: state, reply: reply)
            return
        }
        pendingInstallReply = reply
    }

    override func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        guard !installsWithoutWindow else {
            acknowledgement()
            return
        }
        super.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    override func showDownloadInitiated(cancellation: @escaping () -> Void) {
        guard !installsWithoutWindow else { return }
        super.showDownloadInitiated(cancellation: cancellation)
    }

    override func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        guard !installsWithoutWindow else { return }
        super.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    override func showDownloadDidReceiveData(ofLength length: UInt64) {
        guard !installsWithoutWindow else { return }
        super.showDownloadDidReceiveData(ofLength: length)
    }

    override func showDownloadDidStartExtractingUpdate() {
        guard !installsWithoutWindow else { return }
        super.showDownloadDidStartExtractingUpdate()
    }

    override func showExtractionReceivedProgress(_ progress: Double) {
        guard !installsWithoutWindow else { return }
        super.showExtractionReceivedProgress(progress)
    }

    override func showReadyToInstallAndRelaunch() async -> SPUUserUpdateChoice {
        installsWithoutWindow ? .install : await super.showReadyToInstallAndRelaunch()
    }

    override func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        guard !installsWithoutWindow else { return }
        super.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    override func dismissUpdateInstallation() {
        pendingInstallReply = nil
        installsNextUpdate = false
        let hadWindowlessInstallation = installsWithoutWindow
        installsWithoutWindow = false
        if !hadWindowlessInstallation {
            super.dismissUpdateInstallation()
        }
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    private var updater: SPUUpdater!
    private var userDriver: AppUpdateUserDriver!
    private let defaults: UserDefaults
    private var standardUpdateWindowIsActive = false
    @Published private(set) var presentation = AppUpdatePresentation.hidden
    @Published private(set) var updateChannel: AppUpdateChannel
    private(set) var isConfigured: Bool

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard) {
        let feedURL = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String
        let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        isConfigured = feedURL?.hasPrefix("https://") == true && !(publicKey ?? "").isEmpty
        self.defaults = defaults
        updateChannel = AppUpdateChannel.saved(in: defaults)
        super.init()
        userDriver = AppUpdateUserDriver(hostBundle: bundle, delegate: self)
        updater = SPUUpdater(
            hostBundle: bundle,
            applicationBundle: bundle,
            userDriver: userDriver,
            delegate: self
        )
        if isConfigured {
            do {
                try updater.start()
            } catch {
                isConfigured = false
            }
        }
    }

    var automaticallyChecksForUpdates: Bool {
        isConfigured && updater.automaticallyChecksForUpdates
    }

    var automaticallyDownloadsUpdates: Bool {
        isConfigured && updater.automaticallyDownloadsUpdates
    }

    var updateCheckFrequency: AppUpdateCheckFrequency {
        isConfigured ? .closest(to: updater.updateCheckInterval) : .hourly
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        updateChannel.feedURL
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        updateChannel == .alpha ? [AppUpdateChannel.alpha.rawValue] : []
    }

    func checkForUpdates() {
        guard isConfigured else { return }
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateChecked), .trigger(.user)]
        ))
        updater.checkForUpdates()
    }

    func installAvailableUpdate() {
        guard isConfigured, let version = presentation.version, presentation.allowsAction else { return }
        presentation = .presenting(version: version)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateChecked), .trigger(.user)]
        ))
        // Scheduled checks retain their signed update session. Accept that session
        // directly so the sidebar can own progress without opening Sparkle's window.
        if !userDriver.installAvailableUpdate() {
            updater.checkForUpdates()
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        objectWillChange.send()
        updater.automaticallyChecksForUpdates = enabled
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updatePreferenceChanged), .trigger(.settings), .enabled(enabled)]
        ))
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard isConfigured else { return }
        objectWillChange.send()
        updater.automaticallyDownloadsUpdates = enabled
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updatePreferenceChanged), .trigger(.settings), .enabled(enabled)]
        ))
    }

    func setUpdateCheckFrequency(_ frequency: AppUpdateCheckFrequency) {
        guard isConfigured else { return }
        objectWillChange.send()
        updater.updateCheckInterval = frequency.rawValue
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updatePreferenceChanged), .trigger(.settings)]
        ))
    }

    func setUpdateChannel(_ channel: AppUpdateChannel) {
        guard channel != updateChannel else { return }
        updateChannel = channel
        defaults.set(channel.rawValue, forKey: AppUpdateChannel.preferenceKey)
        presentation = .hidden
        if isConfigured {
            updater.resetUpdateCycleAfterShortDelay()
        }
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updatePreferenceChanged), .trigger(.settings)]
        ))
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        presentation = .available(version: item.displayVersionString)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateAvailable), .outcome(.succeeded), .trigger(.automatic)]
        ))
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        presentation = AppUpdatePresentation
            .downloading(version: item.displayVersionString)
            .keepingCompact(whileStandardWindowIsActive: standardUpdateWindowIsActive)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateDownloadStarted), .trigger(.automatic)]
        ))
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        presentation = AppUpdatePresentation
            .preparingInstallation(version: item.displayVersionString)
            .keepingCompact(whileStandardWindowIsActive: standardUpdateWindowIsActive)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateDownloaded), .outcome(.succeeded), .trigger(.automatic)]
        ))
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        presentation = AppUpdatePresentation
            .failed(version: item.displayVersionString)
            .keepingCompact(whileStandardWindowIsActive: standardUpdateWindowIsActive)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateDownloaded), .outcome(.failed), .trigger(.automatic)]
        ))
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        presentation = AppUpdatePresentation
            .installing(version: item.displayVersionString)
            .keepingCompact(whileStandardWindowIsActive: standardUpdateWindowIsActive)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateInstallStarted), .trigger(.automatic)]
        ))
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        presentation = presentation.completingUpdateCycle(hadError: error != nil)
        ProductAnalytics.shared.capture(AnalyticsEvent(
            .updateLifecycle,
            [.action(.updateCycleCompleted), .outcome(error == nil ? .succeeded : .failed), .trigger(.automatic)]
        ))
    }


    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        standardUpdateWindowIsActive = handleShowingUpdate
        presentation = handleShowingUpdate
            ? .presenting(version: update.displayVersionString)
            : .available(version: update.displayVersionString)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        standardUpdateWindowIsActive = true
        presentation = .presenting(version: update.displayVersionString)
    }

    func standardUserDriverWillFinishUpdateSession() {
        standardUpdateWindowIsActive = false
    }
}
