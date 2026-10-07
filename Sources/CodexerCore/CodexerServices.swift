import Foundation

public protocol CodexInstanceManaging: Sendable {
    func statuses(
        for profiles: [CodexProfile],
        codexAppURL: URL
    ) async throws -> [CodexProfile.ID: CodexInstanceStatus]
    func open(profile: CodexProfile, codexAppURL: URL) async throws -> CodexOpenOutcome
    func close(profile: CodexProfile, codexAppURL: URL) async throws -> CodexCloseOutcome
    func stockStatus(codexAppURL: URL) async throws -> CodexInstanceStatus
    func openStock(
        codexAppURL: URL,
        codexHomeURL: URL,
        configProfile: CodexConfigProfile?
    ) async throws -> CodexOpenOutcome
    func closeStock(codexAppURL: URL) async throws -> CodexCloseOutcome
    func validateCodexApp(at url: URL) async throws
}

extension CodexInstanceController: CodexInstanceManaging {}

public protocol DesktopInstanceManaging: Sendable {
    func statusBatch(for profiles: [CodexProfile], appURLs: [DesktopProduct: URL]) async -> DesktopInstanceStatusBatch
    func statuses(
        for profiles: [CodexProfile],
        appURLs: [DesktopProduct: URL]
    ) async throws -> [CodexProfile.ID: CodexInstanceStatus]
    func open(profile: CodexProfile, appURL: URL) async throws -> CodexOpenOutcome
    func close(profile: CodexProfile, appURL: URL) async throws -> CodexCloseOutcome
    func stockStatus(
        product: DesktopProduct,
        appURL: URL
    ) async throws -> CodexInstanceStatus
    func openStock(
        product: DesktopProduct,
        appURL: URL,
        codexHomeURL: URL?,
        codexConfigProfile: CodexConfigProfile?
    ) async throws -> CodexOpenOutcome
    func closeOfficialCodex(appURL: URL) async throws -> CodexCloseOutcome
    func validateApp(product: DesktopProduct, at url: URL) async throws
}

public extension DesktopInstanceManaging {
    func statusBatch(for profiles: [CodexProfile], appURLs: [DesktopProduct: URL]) async -> DesktopInstanceStatusBatch {
        let managed = (try? await statuses(for: profiles, appURLs: appURLs)) ?? [:]
        var official: [DesktopProduct: CodexInstanceStatus] = [:]
        for (product, url) in appURLs {
            guard !Task.isCancelled else { return DesktopInstanceStatusBatch() }
            official[product] = try? await stockStatus(product: product, appURL: url)
        }
        return DesktopInstanceStatusBatch(managedStatuses: managed, officialStatuses: official)
    }
}

extension DesktopInstanceController: DesktopInstanceManaging {}

public protocol ProfileStatsScanning: Sendable {
    func stats(for profile: CodexProfile, now: Date) -> ProfileStats
    func stats(codexHomeURL: URL, dataRootURL: URL, now: Date) -> ProfileStats
    func stats(
        claudeUserDataURL: URL,
        claudeCodeHomeURL: URL,
        dataRootURL: URL,
        now: Date
    ) -> ProfileStats
}

extension ProfileStatsScanner: ProfileStatsScanning {}

public protocol ProfileRateLimitFetching: Sendable {
    func fetchRateLimits(for profile: CodexProfile, codexAppURL: URL) async -> ProfileRateLimits
    func fetchRateLimits(codexHomeURL: URL, codexAppURL: URL) async -> ProfileRateLimits
    func fetchRateLimits(
        codexHomeURL: URL,
        codexAppURL: URL,
        configProfile: CodexConfigProfile?
    ) async -> ProfileRateLimits
}

public extension ProfileRateLimitFetching {
    func fetchRateLimits(
        codexHomeURL: URL,
        codexAppURL: URL,
        configProfile _: CodexConfigProfile?
    ) async -> ProfileRateLimits {
        await fetchRateLimits(codexHomeURL: codexHomeURL, codexAppURL: codexAppURL)
    }
}

extension AppServerRateLimitClient: ProfileRateLimitFetching {}
extension CodexRateLimitClient: ProfileRateLimitFetching {}

public protocol ShortcutManaging: Sendable {
    func installShortcut(for profile: CodexProfile, codexAppURL: URL) throws
    func removeShortcut(for profile: CodexProfile) throws
    func shortcutExists(for profile: CodexProfile) -> Bool
    func shortcutNeedsRefresh(for profile: CodexProfile) -> Bool
}

public extension ShortcutManaging {
    func shortcutNeedsRefresh(for _: CodexProfile) -> Bool { false }
}

extension ShortcutInstaller: ShortcutManaging {}
