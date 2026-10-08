import Foundation

#if canImport(AppKit)
import AppKit
#endif

public final class ShortcutInstaller: @unchecked Sendable {
    private let fileManager: FileManager
    private let helperExecutableURL: URL?
    private let helperVersion: String

    public init(
        fileManager: FileManager = .default,
        helperExecutableURL: URL? = nil,
        helperVersion: String? = nil
    ) {
        self.fileManager = fileManager
        self.helperExecutableURL = helperExecutableURL
        self.helperVersion = helperVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
    }

    public func installShortcut(for profile: CodexProfile, codexAppURL: URL) throws {
        let operationLock = try ProfileOperationLock.acquireSynchronously(
            for: profile.profileDirectory
        )
        defer { withExtendedLifetime(operationLock) {} }
        let staging = profile.shortcutDirectory
            .appendingPathComponent(".codexer-install-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: staging) }
        try buildShortcut(at: staging, for: profile, codexAppURL: codexAppURL)

        if fileManager.fileExists(atPath: profile.shortcutPath.path) {
            _ = try fileManager.replaceItemAt(profile.shortcutPath, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: profile.shortcutPath)
        }
    }

    private func buildShortcut(at bundleURL: URL, for profile: CodexProfile, codexAppURL: URL) throws {
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent("AgentDockShortcutLauncher")
        try fileManager.copyItem(at: try resolveHelperExecutable(), to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        try infoPlist(for: profile)
            .write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        try shortcutConfig(for: profile, codexAppURL: codexAppURL)
            .write(to: resources.appendingPathComponent("ShortcutConfig.plist"))

        try? createIcon(for: profile, at: resources.appendingPathComponent("ProfileIcon.icns"))
    }

    public func removeShortcut(for profile: CodexProfile) throws {
        let operationLock = try ProfileOperationLock.acquireSynchronously(
            for: profile.profileDirectory
        )
        defer { withExtendedLifetime(operationLock) {} }
        guard fileManager.fileExists(atPath: profile.shortcutPath.path) else {
            return
        }
        try fileManager.removeItem(at: profile.shortcutPath)
    }

    public func shortcutExists(for profile: CodexProfile) -> Bool {
        fileManager.fileExists(atPath: profile.shortcutPath.path)
    }

    public func shortcutNeedsRefresh(for profile: CodexProfile) -> Bool {
        guard shortcutExists(for: profile) else { return false }
        let infoPlistURL = profile.shortcutPath.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? BoundedFileReader.data(
                at: infoPlistURL,
                maximumBytes: LocalControlFileLimit.propertyList
            ),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any],
            let installedVersion = plist["CFBundleVersion"] as? String
        else {
            return true
        }
        return installedVersion.compare(helperVersion, options: .numeric) == .orderedAscending
    }

    private func resolveHelperExecutable() throws -> URL {
        if let helperExecutableURL {
            return helperExecutableURL
        }

        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("AgentDockShortcutLauncher"),
            Bundle.main.executableURL?
                .deletingLastPathComponent()
                .appendingPathComponent("AgentDockShortcutLauncher"),
            Bundle.main.resourceURL?.appendingPathComponent("CodexerShortcutLauncher")
        ].compactMap { $0 }

        if let candidate = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return candidate
        }

        throw ShortcutInstallerError.missingNativeLauncher
    }

    private func shortcutConfig(for profile: CodexProfile, codexAppURL: URL) throws -> Data {
        try PropertyListEncoder().encode(
            IsolatedCodexLaunchConfiguration(profile: profile, codexAppURL: codexAppURL)
        )
    }

    private func infoPlist(for profile: CodexProfile) -> String {
        let bundleIdentifier = "dev.euforic.agentdock.profile.\(profile.product.rawValue).\(profile.slug)"
        let bundleName = shortcutDisplayName(name: profile.name, slug: profile.slug)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>en</string>
            <key>CFBundleExecutable</key>
            <string>AgentDockShortcutLauncher</string>
            <key>CFBundleIconFile</key>
            <string>ProfileIcon</string>
            <key>CFBundleIdentifier</key>
            <string>\(xmlEscaped(bundleIdentifier))</string>
            <key>CFBundleInfoDictionaryVersion</key>
            <string>6.0</string>
            <key>CFBundleName</key>
            <string>\(xmlEscaped(bundleName))</string>
            <key>CFBundleDisplayName</key>
            <string>\(xmlEscaped(bundleName))</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleShortVersionString</key>
            <string>\(xmlEscaped(helperVersion))</string>
            <key>CFBundleVersion</key>
            <string>\(xmlEscaped(helperVersion))</string>
            <key>LSMinimumSystemVersion</key>
            <string>26.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private func createIcon(for profile: CodexProfile, at destination: URL) throws {
        #if canImport(AppKit)
        let iconset = destination
            .deletingLastPathComponent()
            .appendingPathComponent("ProfileIcon.iconset", isDirectory: true)
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: iconset) }

        let sizes = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png")
        ]

        for (size, filename) in sizes {
            let image = renderIcon(profile: profile, size: CGFloat(size))
            guard
                let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                continue
            }
            try pngData.write(to: iconset.appendingPathComponent(filename))
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShortcutInstallerError.iconGenerationFailed
        }
        #endif
    }

    #if canImport(AppKit)
    private func renderIcon(profile: CodexProfile, size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let background = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.07, dy: size * 0.07), xRadius: size * 0.18, yRadius: size * 0.18)
        color(from: profile.iconColor).setFill()
        background.fill()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        background.lineWidth = max(1, size * 0.02)
        background.stroke()

        if profile.iconKind == .image,
           let customImage = NSImage(contentsOf: profile.customIconPath),
           customImage.isValid
        {
            customImage.draw(
                in: rect.insetBy(dx: size * 0.07, dy: size * 0.07),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.high]
            )
            return image
        }

        if profile.iconKind == .symbol,
           let symbol = NSImage(
               systemSymbolName: profile.iconValue.isEmpty ? "person.fill" : profile.iconValue,
               accessibilityDescription: nil
           )
        {
            let symbolSize = size * 0.48
            let symbolRect = NSRect(
                x: (size - symbolSize) / 2,
                y: (size - symbolSize) / 2,
                width: symbolSize,
                height: symbolSize
            )
            let configured = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
            ) ?? symbol
            NSColor.white.set()
            configured.draw(in: symbolRect)
            return image
        }

        let initial = profile.iconValue.isEmpty
            ? String(profile.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
            : String(profile.iconValue.prefix(1)).uppercased()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.48, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let textRect = NSRect(x: 0, y: size * 0.25, width: size, height: size * 0.5)
        initial.draw(in: textRect, withAttributes: attributes)

        return image
    }

    private func color(from hex: String) -> NSColor {
        let clean = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard clean.count == 6, let value = Int(clean, radix: 16) else {
            return NSColor.systemBlue
        }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
    #endif
}

public enum ShortcutInstallerError: Error, LocalizedError, Equatable {
    case missingNativeLauncher
    case iconGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .missingNativeLauncher:
            "AgentDockShortcutLauncher was not found in the AgentDock app bundle."
        case .iconGenerationFailed:
            "AgentDock could not generate the shortcut icon."
        }
    }
}

private func xmlEscaped(_ value: String) -> String {
    value
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "\"", with: "&quot;")
        .replacingOccurrences(of: "'", with: "&apos;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
