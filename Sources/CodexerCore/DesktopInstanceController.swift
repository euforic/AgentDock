import Foundation

public struct DesktopInstanceStatusBatch: Equatable, Sendable {
    public var managedStatuses: [CodexProfile.ID: CodexInstanceStatus]
    public var officialStatuses: [DesktopProduct: CodexInstanceStatus]

    public init(
        managedStatuses: [CodexProfile.ID: CodexInstanceStatus] = [:],
        officialStatuses: [DesktopProduct: CodexInstanceStatus] = [:]
    ) {
        self.managedStatuses = managedStatuses
        self.officialStatuses = officialStatuses
    }
}

struct ProviderInstanceStatusBatch: Sendable {
    var managedStatuses: [CodexProfile.ID: CodexInstanceStatus]
    var officialStatus: CodexInstanceStatus
}

public actor DesktopInstanceController {
    private let codexController: CodexInstanceController
    private let claudeController: ClaudeInstanceController

    public init(
        codexController: CodexInstanceController = CodexInstanceController(),
        claudeController: ClaudeInstanceController = ClaudeInstanceController()
    ) {
        self.codexController = codexController
        self.claudeController = claudeController
    }

    /// Failed or unselected providers contribute no entries, so callers can
    /// retain their last successful status independently for each provider.
    public func statusBatch(
        for profiles: [CodexProfile],
        appURLs: [DesktopProduct: URL]
    ) async -> DesktopInstanceStatusBatch {
        var result = DesktopInstanceStatusBatch()
        for product in DesktopProduct.allCases {
            guard !Task.isCancelled else { return DesktopInstanceStatusBatch() }
            guard let appURL = appURLs[product] else { continue }
            let providerProfiles = profiles.filter { $0.product == product }
            do {
                let batch: ProviderInstanceStatusBatch
                switch product {
                case .codex:
                    batch = try await codexController.statusBatch(
                        for: providerProfiles,
                        codexAppURL: appURL
                    )
                case .claude:
                    batch = try await claudeController.statusBatch(
                        for: providerProfiles,
                        appURL: appURL
                    )
                }
                guard !Task.isCancelled else { return DesktopInstanceStatusBatch() }
                result.managedStatuses.merge(batch.managedStatuses) { _, latest in latest }
                result.officialStatuses[product] = batch.officialStatus
            } catch {
                // A provider inspection failure does not discard another
                // provider's successful result.
                continue
            }
        }
        return Task.isCancelled ? DesktopInstanceStatusBatch() : result
    }

    public func statuses(
        for profiles: [CodexProfile],
        appURLs: [DesktopProduct: URL]
    ) async throws -> [CodexProfile.ID: CodexInstanceStatus] {
        var result: [CodexProfile.ID: CodexInstanceStatus] = [:]
        let codexProfiles = profiles.filter { $0.product == .codex }
        if !codexProfiles.isEmpty {
            guard let appURL = appURLs[.codex] else {
                throw DesktopInstanceControllerError.missingAppSelection(.codex)
            }
            result.merge(
                try await codexController.statuses(
                    for: codexProfiles,
                    codexAppURL: appURL
                )
            ) { _, latest in latest }
        }
        let claudeProfiles = profiles.filter { $0.product == .claude }
        if !claudeProfiles.isEmpty {
            guard let appURL = appURLs[.claude] else {
                throw DesktopInstanceControllerError.missingAppSelection(.claude)
            }
            result.merge(
                try await claudeController.statuses(
                    for: claudeProfiles,
                    appURL: appURL
                )
            ) { _, latest in latest }
        }
        return result
    }

    public func open(
        profile: CodexProfile,
        appURL: URL
    ) async throws -> CodexOpenOutcome {
        switch profile.product {
        case .codex:
            return try await codexController.open(
                profile: profile,
                codexAppURL: appURL
            )
        case .claude:
            return try await claudeController.open(profile: profile, appURL: appURL)
        }
    }

    public func open(
        configuration: IsolatedCodexLaunchConfiguration
    ) async throws -> CodexOpenOutcome {
        switch configuration.resolvedProduct {
        case .codex:
            return try await codexController.open(configuration: configuration)
        case .claude:
            guard let profileID = configuration.profileID,
                  let profileSlug = configuration.profileSlug,
                  let userDataURL = configuration.claudeUserDataURL
            else {
                throw DesktopInstanceControllerError.invalidShortcutConfiguration
            }
            let profile = CodexProfile(
                id: profileID,
                product: .claude,
                name: profileSlug,
                slug: profileSlug,
                profileDirectory: userDataURL.deletingLastPathComponent(),
                shortcutDirectory: userDataURL.deletingLastPathComponent()
            )
            return try await claudeController.open(
                profile: profile,
                appURL: configuration.appURL
            )
        }
    }

    public func close(
        profile: CodexProfile,
        appURL: URL
    ) async throws -> CodexCloseOutcome {
        switch profile.product {
        case .codex:
            return try await codexController.close(
                profile: profile,
                codexAppURL: appURL
            )
        case .claude:
            return try await claudeController.close(profile: profile, appURL: appURL)
        }
    }

    public func stockStatus(
        product: DesktopProduct,
        appURL: URL
    ) async throws -> CodexInstanceStatus {
        switch product {
        case .codex:
            return try await codexController.stockStatus(codexAppURL: appURL)
        case .claude:
            return try await claudeController.stockStatus(appURL: appURL)
        }
    }

    public func openStock(
        product: DesktopProduct,
        appURL: URL,
        codexHomeURL: URL?,
        codexConfigProfile: CodexConfigProfile?
    ) async throws -> CodexOpenOutcome {
        switch product {
        case .codex:
            guard let codexHomeURL else {
                throw DesktopInstanceControllerError.invalidShortcutConfiguration
            }
            return try await codexController.openStock(
                codexAppURL: appURL,
                codexHomeURL: codexHomeURL,
                configProfile: codexConfigProfile
            )
        case .claude:
            return try await claudeController.openStock(appURL: appURL)
        }
    }

    public func closeOfficialCodex(appURL: URL) async throws -> CodexCloseOutcome {
        try await codexController.closeStock(codexAppURL: appURL)
    }

    public func validateApp(
        product: DesktopProduct,
        at appURL: URL
    ) async throws {
        switch product {
        case .codex:
            try await codexController.validateCodexApp(at: appURL)
        case .claude:
            try await claudeController.validateClaudeApp(at: appURL)
        }
    }
}

public enum DesktopInstanceControllerError: Error, LocalizedError, Equatable {
    case missingAppSelection(DesktopProduct)
    case invalidShortcutConfiguration

    public var errorDescription: String? {
        switch self {
        case let .missingAppSelection(product):
            "No \(product.displayName) Desktop app is selected."
        case .invalidShortcutConfiguration:
            "The profile shortcut is missing its managed Claude UserData identity."
        }
    }
}
