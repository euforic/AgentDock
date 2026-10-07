import AppKit
import CodexerCore
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
    case .logs: "Logs & Errors"
    case .lastActivity: "Latest Activity"
    case .archived: "Archived Sessions"
    case .sessions: "Sessions"
    }
  }

  var icon: String {
    switch self {
    case .storage: "externaldrive"
    case .logs: "doc.text.magnifyingglass"
    case .lastActivity: "waveform.path.ecg"
    case .archived: "archivebox"
    case .sessions: "bubble.left.and.bubble.right"
    }
  }
}

struct ActivityDetailSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var model: CodexerModel

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
    VStack(alignment: .leading, spacing: 0) {
      header
      Divider().overlay(AgentDockPalette.divider)
      content
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      Divider().overlay(AgentDockPalette.divider)
      footer
    }
    .frame(width: 720, height: 520)
    .background(AgentDockPalette.graphite)
    .task(id: loadKey) {
      await loadActivity()
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Image(systemName: destination.icon)
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(AgentDockPalette.blue)
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(destination.title)
          .font(.system(size: 20, weight: .semibold))
        Text(contextName)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      Spacer()
      if loading {
        ProgressView()
          .controlSize(.small)
          .accessibilityLabel("Loading \(destination.title.lowercased())")
      }
    }
    .padding(.horizontal, 20)
    .frame(height: 62)
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
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        ActivitySummaryRow(
          label: "Total local data",
          value: {
            let formatted = ByteCountFormatter.agentDock.string(fromByteCount: stats.dataBytes)
            return stats.dataSizeIsTruncated ? "At least \(formatted)" : formatted
          }()
        )

        if let measuredAt = stats.dataSizeMeasuredAt {
          Text("Storage measured \(measuredAt.formatted(date: .omitted, time: .shortened)); reused for up to 10 minutes.")
            .font(.caption).foregroundStyle(.secondary)
        }
        SectionLabel(title: "Locations")
        VStack(spacing: 0) {
          ForEach(Array(storageLocations.enumerated()), id: \.offset) { index, location in
            if index > 0 {
              Divider().overlay(AgentDockPalette.divider)
            }
            ActivityPathRow(location: location)
          }
        }
        .background(AgentDockPalette.panel.opacity(0.42), in: .rect(cornerRadius: 8))

        Text("Paths stay local. Full paths are copied or revealed only when you choose an action.")
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      .padding(20)
    }
  }

  private var logsContent: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Picker("Log Level", selection: $logFilter) {
          ForEach(ActivityLogFilter.allCases) { filter in
            Text(filter.title).tag(filter)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: 240)

        HStack(spacing: 7) {
          Image(systemName: "magnifyingglass")
            .foregroundStyle(.secondary)
          TextField("Search logs", text: $logSearch)
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 7))

        Spacer()
        Text(logSummary)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .frame(height: 48)

      Divider().overlay(AgentDockPalette.divider)

      if loading, snapshot == nil {
        ProgressView("Reading local logs…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let loadError {
        ActivityUnavailableState(
          title: "Logs Unavailable",
          description: loadError,
          actionTitle: "Try Again"
        ) {
          Task { await loadActivity(force: true) }
        }
      } else if filteredLogs.isEmpty {
        ActivityUnavailableState(
          title: logSearch.isEmpty ? "No Matching Log Entries" : "No Search Results",
          description: "No local entries match the selected level and search."
        )
      } else {
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(filteredLogs, id: \.self) { entry in
              ActivityLogRow(entry: entry)
              Divider()
                .overlay(AgentDockPalette.divider)
                .padding(.leading, 52)
            }
          }
        }
      }

      activityIssues
    }
  }

  private var activityContent: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        VStack(spacing: 0) {
          ActivitySummaryRow(
            label: "Latest local activity",
            value: stats.lastActivityAt?.formatted(date: .abbreviated, time: .shortened)
              ?? "Unavailable"
          )
          Divider().overlay(AgentDockPalette.divider)
          ActivitySummaryRow(label: "Total sessions", value: stats.totalSessions.formatted())
          Divider().overlay(AgentDockPalette.divider)
          ActivitySummaryRow(label: "Active", value: stats.activeSessions.formatted())
          Divider().overlay(AgentDockPalette.divider)
          ActivitySummaryRow(label: "This week", value: stats.weeklySessions.formatted())
          Divider().overlay(AgentDockPalette.divider)
          ActivitySummaryRow(label: "Weekly tokens", value: stats.weeklyTokens.formatted())
        }
        .background(AgentDockPalette.panel.opacity(0.42), in: .rect(cornerRadius: 8))
      }
      .padding(20)
    }
  }

  private var archivedContent: some View {
    Group {
      if loading, snapshot == nil {
        ProgressView("Reading archived sessions…")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let loadError {
        ActivityUnavailableState(
          title: "Archived Sessions Unavailable",
          description: loadError,
          actionTitle: "Try Again"
        ) {
          Task { await loadActivity(force: true) }
        }
      } else if snapshot?.archivedThreads.isEmpty != false {
        ActivityUnavailableState(
          title: "No Archived Sessions",
          description: "Archived local sessions for this profile will appear here."
        )
      } else {
        VStack(spacing: 0) {
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(snapshot?.archivedThreads ?? []) { thread in
                ArchivedThreadRow(thread: thread)
                Divider()
                  .overlay(AgentDockPalette.divider)
                  .padding(.leading, 52)
              }
            }
          }
          activityIssues
        }
      }
    }
  }

  @ViewBuilder
  private var activityIssues: some View {
    if let issues = snapshot?.issues, !issues.isEmpty {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(issues, id: \.self) { issue in
          Label(issue.message, systemImage: "exclamationmark.triangle")
            .font(.system(size: 11))
            .foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.orange.opacity(0.06))
    }
  }

  private var footer: some View {
    HStack {
      if destination == .storage {
        Button("Reveal Data") {
          revealRoot()
        }
        .buttonStyle(.bordered)
      }
      Spacer()
      Button("Done") {
        dismiss()
      }
      .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 16)
    .frame(height: 50)
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
      return [
        ActivityStorageLocation(
          title: product == .codex ? "Codex Home" : "Claude Data",
          subtitle: rootURL.lastPathComponent,
          url: rootURL
        )
      ]
    }

    var locations = [
      ActivityStorageLocation(
        title: "Profile Data",
        subtitle: profile.profileDirectory.lastPathComponent,
        url: profile.profileDirectory
      )
    ]
    if profile.product == .codex {
      locations.append(
        ActivityStorageLocation(
          title: "Codex Home",
          subtitle: profile.codexHomePath.lastPathComponent,
          url: profile.codexHomePath
        )
      )
      locations.append(
        ActivityStorageLocation(
          title: "App Data",
          subtitle: profile.electronUserDataPath.lastPathComponent,
          url: profile.electronUserDataPath
        )
      )
    } else {
      locations.append(
        ActivityStorageLocation(
          title: "User Data",
          subtitle: profile.claudeUserDataPath.lastPathComponent,
          url: profile.claudeUserDataPath
        )
      )
    }
    return locations
  }

  private var filteredLogs: [LocalActivityLogEntry] {
    (snapshot?.logs ?? []).filter { entry in
      logFilter.includes(entry.level)
        && (logSearch.isEmpty
          || entry.message.localizedCaseInsensitiveContains(logSearch)
          || entry.target.localizedCaseInsensitiveContains(logSearch))
    }
  }

  private var logSummary: String {
    let logs = snapshot?.logs ?? []
    let errors = logs.filter { $0.level.uppercased() == "ERROR" }.count
    let warnings = logs.filter {
      ["WARN", "WARNING"].contains($0.level.uppercased())
    }.count
    return "\(errors) errors · \(warnings) warnings"
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
    loadError = nil
    do {
      let result = try await LocalActivityReader().read(codexHomeURL: codexHomeURL)
      guard !Task.isCancelled else { return }
      snapshot = result
    } catch {
      guard !Task.isCancelled else { return }
      loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
    loading = false
  }

  private func revealRoot() {
    if let profile {
      model.revealData(profile)
    } else {
      model.revealOfficialData(product)
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

private struct ActivityStorageLocation {
  let title: String
  let subtitle: String
  let url: URL
}

private struct ActivityPathRow: View {
  @EnvironmentObject private var model: CodexerModel
  let location: ActivityStorageLocation

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "folder")
        .foregroundStyle(.secondary)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(location.title)
          .font(.system(size: 13, weight: .medium))
        Text(location.subtitle)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button("Reveal") {
        NSWorkspace.shared.activateFileViewerSelecting([location.url])
      }
      .buttonStyle(.bordered)
      Button("Copy") {
        model.copyPath(location.url)
      }
      .buttonStyle(.bordered)
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 48)
  }
}

private struct ActivitySummaryRow: View {
  let label: String
  let value: String

  var body: some View {
    HStack {
      Text(label)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
    }
    .font(.system(size: 13))
    .padding(.horizontal, 14)
    .frame(minHeight: 44)
    .accessibilityElement(children: .combine)
  }
}

private struct ActivityLogRow: View {
  let entry: LocalActivityLogEntry

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: levelIcon)
        .foregroundStyle(levelColor)
        .frame(width: 24)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text(entry.level.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(levelColor)
          Text(entry.target)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer()
          Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        Text(entry.message.isEmpty ? "No message was recorded." : entry.message)
          .font(.system(size: 13))
          .lineLimit(3)
          .textSelection(.enabled)
        if let source = entry.source {
          Text(source)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
  }

  private var levelIcon: String {
    switch entry.level.uppercased() {
    case "ERROR": "xmark.octagon.fill"
    case "WARN", "WARNING": "exclamationmark.triangle.fill"
    default: "info.circle"
    }
  }

  private var levelColor: Color {
    switch entry.level.uppercased() {
    case "ERROR": .red
    case "WARN", "WARNING": .orange
    default: .secondary
    }
  }
}

private struct ArchivedThreadRow: View {
  let thread: LocalArchivedThreadSummary

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "archivebox")
        .foregroundStyle(.secondary)
        .frame(width: 24)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 4) {
        Text(thread.title.isEmpty ? "Untitled session" : thread.title)
          .font(.system(size: 13, weight: .medium))
          .lineLimit(2)
        Text([thread.repository, thread.branch].compactMap { $0 }.joined(separator: " · "))
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        HStack {
          Text((thread.archivedAt ?? thread.updatedAt).formatted(
            date: .abbreviated,
            time: .shortened
          ))
          Spacer()
          Text("\(thread.tokenCount.formatted()) tokens")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
      }
      Text(maskedID)
        .font(.system(size: 10).monospaced())
        .foregroundStyle(.tertiary)
        .textSelection(.enabled)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 9)
    .accessibilityElement(children: .combine)
  }

  private var maskedID: String {
    guard thread.id.count > 12 else { return thread.id }
    return "\(thread.id.prefix(7))…\(thread.id.suffix(5))"
  }
}

private struct ActivityUnavailableState: View {
  let title: String
  let description: String
  var actionTitle: String?
  var action: (() -> Void)?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: "tray")
        .font(.system(size: 30, weight: .light))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.system(size: 17, weight: .semibold))
      Text(description)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 360)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
          .buttonStyle(.bordered)
      }
    }
    .padding(24)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
