import AppKit
import AgentDockCore
import SwiftUI

enum ActivityDestination: String, Identifiable {
    case storage
    case logs
    case lastActivity
    case archived
    case sessions

    var id: Self { self }

    var title: String {
        switch self {
        case .storage: "Storage"
        case .logs: "Logs"
        case .lastActivity: "Latest Activity"
        case .archived: "Archived Sessions"
        case .sessions: "Sessions"
        }
    }
}

struct ActivityDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AgentDockModel

    private let profile: CodexProfile?
    private let officialProduct: DesktopProduct?
    let destination: ActivityDestination

    @State private var snapshot: LocalActivitySnapshot?
    @State private var loading = false
    @State private var loadError: String?
    @State private var logFilter: ActivityLogFilter = .all
    @State private var logSearch = ""

    init(profile: CodexProfile, destination: ActivityDestination) {
        self.profile = profile
        officialProduct = nil
        self.destination = destination
    }

    init(officialProduct: DesktopProduct, destination: ActivityDestination) {
        profile = nil
        self.officialProduct = officialProduct
        self.destination = destination
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let issues = snapshot?.issues, !issues.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(issues, id: \.self) { issue in
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 440, idealHeight: 540)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task(id: loadKey) {
            await loadActivity()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title)
                    .font(.title3.weight(.semibold))
                Text(contextName)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if destination == .logs {
                Picker("Level", selection: $logFilter) {
                    ForEach(ActivityLogFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search", text: $logSearch, prompt: Text("Search Logs"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            if destination == .storage {
                Button("Show in Finder", action: revealRoot)
            }
            if loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading \(destination.title.lowercased())")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .storage:
            storageContent
        case .logs:
            logsContent
        case .lastActivity, .sessions:
            activityContent
        case .archived:
            archivedContent
        }
    }

    private var storageContent: some View {
        Form {
            Section {
                LabeledContent("Total local data", value: storageSize)
            } footer: {
                if let measuredAt = stats.dataSizeMeasuredAt {
                    Text("Measured at \(measuredAt.formatted(date: .omitted, time: .shortened)) and reused for up to 10 minutes.")
                }
            }
            Section {
                ForEach(storageLocations) { location in
                    PathRow(title: location.title, url: location.url)
                }
            } header: {
                Text("Locations")
            } footer: {
                Text("Paths stay on this Mac. Full paths are copied or shown only when you choose an action.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var logsContent: some View {
        if loading, snapshot == nil {
            ProgressView("Reading Local Logs…")
        } else if let loadError {
            unavailable("Logs Unavailable", description: loadError, retry: true)
        } else if filteredLogs.isEmpty {
            unavailable(
                logSearch.isEmpty ? "No Log Entries" : "No Results",
                description: logSearch.isEmpty
                    ? "No local entries match the selected level."
                    : "No local entries match “\(logSearch)”."
            )
        } else {
            Table(filteredLogs) {
                TableColumn("Level") { row in
                    Label(row.entry.level.uppercased(), systemImage: row.levelIcon)
                        .foregroundStyle(row.levelColor)
                        .labelStyle(.titleAndIcon)
                }
                .width(min: 70, ideal: 84, max: 100)
                TableColumn("Time") { row in
                    Text(row.entry.timestamp.formatted(date: .abbreviated, time: .standard))
                        .monospacedDigit()
                }
                .width(min: 120, ideal: 150)
                TableColumn("Source") { row in
                    Text(row.entry.target)
                        .foregroundStyle(.secondary)
                        .help(row.entry.source ?? row.entry.target)
                }
                .width(min: 80, ideal: 140)
                TableColumn("Message") { row in
                    Text(row.entry.message.isEmpty ? "No message was recorded." : row.entry.message)
                        .lineLimit(2)
                        .help(row.entry.message)
                        .textSelection(.enabled)
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private var activityContent: some View {
        Form {
            Section {
                LabeledContent(
                    "Latest local activity",
                    value: stats.lastActivityAt?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable"
                )
                LabeledContent("Total sessions", value: stats.totalSessions.formatted())
                LabeledContent("Active", value: stats.activeSessions.formatted())
                LabeledContent("This week", value: stats.weeklySessions.formatted())
                LabeledContent("Tokens this week", value: stats.weeklyTokens.formatted())
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var archivedContent: some View {
        if loading, snapshot == nil {
            ProgressView("Reading Archived Sessions…")
        } else if let loadError {
            unavailable("Archived Sessions Unavailable", description: loadError, retry: true)
        } else if let threads = snapshot?.archivedThreads, !threads.isEmpty {
            Table(threads) {
                TableColumn("Session") { thread in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(thread.title.isEmpty ? "Untitled session" : thread.title)
                            .lineLimit(1)
                        let location = [thread.repository, thread.branch].compactMap { $0 }.joined(separator: " · ")
                        if !location.isEmpty {
                            Text(location)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .help(thread.title)
                }
                TableColumn("Archived") { thread in
                    Text((thread.archivedAt ?? thread.updatedAt).formatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .width(min: 120, ideal: 150)
                TableColumn("Tokens") { thread in
                    Text(thread.tokenCount.formatted())
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 90)
                TableColumn("ID") { thread in
                    Text(Self.maskedID(thread.id))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .width(min: 90, ideal: 120)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
        } else {
            unavailable("No Archived Sessions", description: "Archived local sessions for this profile appear here.")
        }
    }

    private func unavailable(_ title: String, description: String, retry: Bool = false) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "tray")
        } description: {
            Text(description)
        } actions: {
            if retry {
                Button("Try Again") {
                    Task { await loadActivity(force: true) }
                }
            }
        }
    }

    private var contextName: String {
        if let profile {
            return "\(profile.name) · \(profile.product.displayName)"
        }
        return "Official \(product.displayName)"
    }

    private var product: DesktopProduct {
        profile?.product ?? officialProduct ?? .codex
    }

    private var stats: ProfileStats {
        if let profile {
            return model.stats(for: profile)
        }
        return product == .codex ? model.officialCodexStats : model.officialClaudeStats
    }

    private var storageSize: String {
        let formatted = ByteCountFormatter.agentDock.string(fromByteCount: stats.dataBytes)
        return stats.dataSizeIsTruncated ? "At least \(formatted)" : formatted
    }

    private var codexHomeURL: URL? {
        if let profile {
            return profile.product == .codex ? profile.codexHomePath : nil
        }
        guard product == .codex else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
    }

    private var rootURL: URL {
        if let profile {
            return profile.profileDirectory
        }
        switch product {
        case .codex:
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        case .claude:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Claude", isDirectory: true)
        }
    }

    private var storageLocations: [ActivityStorageLocation] {
        guard let profile else {
            return [ActivityStorageLocation(title: product == .codex ? "Codex Home" : "Claude Data", url: rootURL)]
        }
        var locations = [ActivityStorageLocation(title: "Profile Data", url: profile.profileDirectory)]
        if profile.product == .codex {
            locations.append(ActivityStorageLocation(title: "Codex Home", url: profile.codexHomePath))
            locations.append(ActivityStorageLocation(title: "App Data", url: profile.electronUserDataPath))
        } else {
            locations.append(ActivityStorageLocation(title: "User Data", url: profile.claudeUserDataPath))
        }
        return locations
    }

    private var filteredLogs: [ActivityLogRow] {
        (snapshot?.logs ?? []).enumerated().compactMap { index, entry in
            guard logFilter.includes(entry.level),
                  logSearch.isEmpty
                    || entry.message.localizedCaseInsensitiveContains(logSearch)
                    || entry.target.localizedCaseInsensitiveContains(logSearch)
            else { return nil }
            // Position is the identity: identical log lines are distinct records.
            return ActivityLogRow(id: index, entry: entry)
        }
    }

    private var loadKey: String {
        "\(destination.rawValue)-\(codexHomeURL?.path ?? product.rawValue)"
    }

    private func loadActivity(force: Bool = false) async {
        guard destination == .logs || destination == .archived else { return }
        guard let codexHomeURL else {
            loadError = "This provider does not expose a supported local activity database."
            return
        }
        if snapshot != nil, !force { return }

        loading = true
        defer { loading = false }
        loadError = nil
        do {
            let result = try await LocalActivityReader().read(codexHomeURL: codexHomeURL)
            guard !Task.isCancelled else { return }
            snapshot = result
        } catch {
            guard !Task.isCancelled else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func revealRoot() {
        if let profile {
            model.revealData(profile)
        } else {
            model.revealOfficialData(product)
        }
    }

    private static func maskedID(_ id: String) -> String {
        guard id.count > 12 else { return id }
        return "\(id.prefix(7))…\(id.suffix(5))"
    }
}

private struct ActivityStorageLocation: Identifiable {
    let title: String
    let url: URL
    var id: String { title }
}

private struct ActivityLogRow: Identifiable {
    let id: Int
    let entry: LocalActivityLogEntry

    var levelIcon: String {
        switch entry.level.uppercased() {
        case "ERROR": "xmark.octagon.fill"
        case "WARN", "WARNING": "exclamationmark.triangle.fill"
        default: "info.circle"
        }
    }

    var levelColor: Color {
        switch entry.level.uppercased() {
        case "ERROR": .red
        case "WARN", "WARNING": .orange
        default: .secondary
        }
    }
}

private enum ActivityLogFilter: String, CaseIterable, Identifiable {
    case all
    case warnings
    case errors

    var id: Self { self }
    var title: String { rawValue.capitalized }

    func includes(_ level: String) -> Bool {
        switch self {
        case .all:
            return true
        case .warnings:
            return ["WARN", "WARNING"].contains(level.uppercased())
        case .errors:
            return level.uppercased() == "ERROR"
        }
    }
}
