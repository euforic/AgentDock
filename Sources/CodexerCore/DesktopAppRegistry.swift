import Foundation
import Security

public struct DesktopAppDescriptor: Equatable, Sendable {
    public let product: DesktopProduct
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let executableName: String
    public let defaultAppURL: URL

    public func executableURL(for appURL: URL) -> URL {
        appURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
    }
}

public enum DesktopAppRegistry {
    public static let codex = DesktopAppDescriptor(
        product: .codex,
        bundleIdentifier: "com.openai.codex",
        teamIdentifier: "2DC432GLL2",
        executableName: "Codex",
        defaultAppURL: URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    )

    public static let claude = DesktopAppDescriptor(
        product: .claude,
        bundleIdentifier: "com.anthropic.claudefordesktop",
        teamIdentifier: "Q6L2SF6YDW",
        executableName: "Claude",
        defaultAppURL: URL(fileURLWithPath: "/Applications/Claude.app", isDirectory: true)
    )

    public static func descriptor(for product: DesktopProduct) -> DesktopAppDescriptor {
        switch product {
        case .codex: codex
        case .claude: claude
        }
    }
}

public struct OfficialDesktopAppValidator: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validateApp(at url: URL, product: DesktopProduct) throws {
        let descriptor = DesktopAppRegistry.descriptor(for: product)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw DesktopAppValidationError.appMissing(product, url.path)
        }

        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? BoundedFileReader.data(
                  at: infoPlistURL,
                  maximumBytes: LocalControlFileLimit.propertyList
              ),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data,
                  format: nil
              ) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == descriptor.bundleIdentifier
        else {
            throw DesktopAppValidationError.invalidBundle(product, url.path)
        }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            throw DesktopAppValidationError.invalidSignature(product, url.path)
        }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            Self.requirementText(for: descriptor) as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  requirement
              ) == errSecSuccess
        else {
            throw DesktopAppValidationError.invalidSignature(product, url.path)
        }
    }

    public func isTrustedProcess(
        processID: Int32,
        product: DesktopProduct
    ) -> Bool {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID)
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code
        else {
            return false
        }

        let descriptor = DesktopAppRegistry.descriptor(for: product)
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            Self.requirementText(for: descriptor) as CFString,
            [],
            &requirement
        ) == errSecSuccess,
              let requirement
        else {
            return false
        }
        return SecCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            requirement
        ) == errSecSuccess
    }

    private static func requirementText(for descriptor: DesktopAppDescriptor) -> String {
        """
        anchor apple generic and identifier "\(descriptor.bundleIdentifier)" \
        and certificate leaf[subject.OU] = "\(descriptor.teamIdentifier)"
        """
    }
}

public enum DesktopAppValidationError: Error, LocalizedError, Equatable {
    case appMissing(DesktopProduct, String)
    case invalidBundle(DesktopProduct, String)
    case invalidSignature(DesktopProduct, String)

    public var errorDescription: String? {
        switch self {
        case let .appMissing(product, path):
            "\(product.displayName) Desktop was not found at \(path)."
        case let .invalidBundle(product, path):
            "\(path) is not the official \(product.displayName) Desktop app."
        case let .invalidSignature(product, path):
            "\(product.displayName) Desktop at \(path) is not signed by its expected publisher."
        }
    }
}

public struct ClaudeDesktopContractProbe: @unchecked Sendable {
    public static let maximumArchiveBytes = 256 * 1_024 * 1_024
    public static let maximumContractWindowBytes = 8 * 1_024

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validate(appURL: URL) throws {
        let archiveURL = appURL.appendingPathComponent("Contents/Resources/app.asar")
        let values = try? archiveURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true,
              let fileSize = values?.fileSize,
              fileSize > 0,
              fileSize <= Self.maximumArchiveBytes,
              let data = try? Data(contentsOf: archiveURL, options: [.mappedIfSafe])
        else {
            throw ClaudeDesktopContractError.unsupportedBuild
        }

        let marker = Data("CLAUDE_USER_DATA_DIR".utf8)
        let userDataSetPaths = [
            Data(#"setPath("userData""#.utf8),
            Data("setPath(`userData`".utf8)
        ]
        let logsSetPaths = [
            Data(#"setPath("logs""#.utf8),
            Data("setPath(`logs`".utf8)
        ]
        var searchStart = data.startIndex
        while searchStart < data.endIndex,
              let markerRange = data.range(
                  of: marker,
                  options: [],
                  in: searchStart..<data.endIndex
              )
        {
            let windowEnd = min(
                data.endIndex,
                markerRange.lowerBound + Self.maximumContractWindowBytes
            )
            let contractWindow = data[markerRange.lowerBound..<windowEnd]
            if userDataSetPaths.contains(where: { contractWindow.range(of: $0) != nil }),
               logsSetPaths.contains(where: { contractWindow.range(of: $0) != nil })
            {
                return
            }
            searchStart = markerRange.upperBound
        }
        throw ClaudeDesktopContractError.unsupportedBuild
    }
}

public enum ClaudeDesktopContractError: Error, LocalizedError, Equatable {
    case unsupportedBuild

    public var errorDescription: String? {
        "This signed Claude Desktop build no longer exposes AgentDock's verified CLAUDE_USER_DATA_DIR startup contract. Update AgentDock before launching a managed Claude profile."
    }
}
