import AppKit
import AgentDockCore
import SwiftUI

extension AgentDockAppearance {
    /// nil follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension DesktopProduct {
    /// Provider usage meters keep a stable hue that is distinct from the accent color.
    var usageTint: Color {
        switch self {
        case .codex: .blue
        case .claude: .orange
        }
    }
}

/// Decoded profile and provider icons, keyed by file identity so edits are picked up.
@MainActor
enum IconImageCache {
    private static let images = NSCache<NSString, NSImage>()

    static func profileImage(at url: URL) -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let values else { return nil }
        let key = "\(url.path)|\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values.fileSize ?? 0)"
            as NSString
        if let image = images.object(forKey: key) { return image }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    static func applicationIcon(at url: URL) -> NSImage {
        let key = "app|\(url.path)" as NSString
        if let image = images.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        images.setObject(image, forKey: key)
        return image
    }
}

struct ProfileIconView: View {
    let profile: CodexProfile
    var size: CGFloat = 48

    var body: some View {
        ProfileIconArtwork(
            name: profile.name,
            kind: profile.iconKind,
            value: profile.iconValue,
            color: profile.iconColor,
            image: profile.iconKind == .image ? IconImageCache.profileImage(at: profile.customIconPath) : nil,
            size: size
        )
    }
}

/// The shared icon drawing used by the sidebar, detail views, and the editor preview.
struct ProfileIconArtwork: View {
    let name: String
    let kind: ProfileIconKind
    let value: String
    let color: String
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if kind == .image, let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [Color(hex: color), Color(hex: color).opacity(0.72)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    if kind == .symbol || monogram.isEmpty {
                        Image(systemName: kind == .symbol && !value.isEmpty ? value : "person.fill")
                            .font(.system(size: size * 0.44, weight: .medium))
                    } else {
                        Text(monogram)
                            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size * 0.225, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private var monogram: String {
        let source = value.isEmpty ? name.trimmingCharacters(in: .whitespaces) : value
        return String(source.prefix(1)).uppercased()
    }
}

struct ProviderIconView: View {
    let product: DesktopProduct
    let appURL: URL
    var size: CGFloat = 40

    var body: some View {
        Image(nsImage: IconImageCache.applicationIcon(at: appURL))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A small running badge drawn over the corner of a source icon.
struct RunningBadge: ViewModifier {
    let isRunning: Bool
    var diameter: CGFloat = 8

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottomTrailing) {
            if isRunning {
                Circle()
                    .fill(.green)
                    .frame(width: diameter, height: diameter)
                    .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                    .offset(x: diameter * 0.3, y: diameter * 0.3)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension View {
    func runningBadge(_ isRunning: Bool, diameter: CGFloat = 8) -> some View {
        modifier(RunningBadge(isRunning: isRunning, diameter: diameter))
    }
}

/// Running state as an inline label, for detail rows.
struct RunningStatusLabel: View {
    let isRunning: Bool?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isRunning == true ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(isRunning.map { $0 ? "Running" : "Not Running" } ?? "Status Unavailable")
        }
    }
}

/// A drill-in row in a grouped form, matching System Settings.
struct FormNavigationRow: View {
    let title: String
    let systemImage: String
    var value: String?
    var valueStyle: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer(minLength: 12)
                if let value {
                    Text(value)
                        .foregroundStyle(valueStyle)
                        .lineLimit(1)
                }
                Image(systemName: "chevron.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A path with Finder and copy actions, used for profile and provider locations.
struct PathRow: View {
    @EnvironmentObject private var model: AgentDockModel
    let title: String
    let url: URL
    var detail: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(detail ?? url.abbreviatedPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(url.abbreviatedPath)
                Button("Show in Finder", systemImage: "magnifyingglass.circle.fill") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Show in Finder")
                Button("Copy Path", systemImage: "document.on.document") {
                    model.copyPath(url)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Copy Path")
            }
        } label: {
            Text(title)
        }
    }
}

extension URL {
    var abbreviatedPath: String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

extension Bundle {
    /// Version of another installed application, reread only when its Info.plist changes.
    @MainActor
    static func shortVersion(ofAppAt url: URL) -> String? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let modified = (try? infoURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(modified)"
        if let cached = appVersions[key] { return cached }
        let version = NSDictionary(contentsOf: infoURL)?["CFBundleShortVersionString"] as? String
        appVersions[key] = version
        return version
    }

    @MainActor private static var appVersions: [String: String?] = [:]
}

@MainActor
extension ByteCountFormatter {
    static let agentDock: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter
    }()
}
