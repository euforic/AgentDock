import AppKit
import CodexerCore
import SwiftUI

struct AdvancedView: View {
  @EnvironmentObject private var model: CodexerModel

  var body: some View {
    Group {
      if let profile = model.selectedProfile {
        ProfileAdvancedView(profile: profile)
      } else if let product = model.selectedOfficialProduct {
        OfficialAdvancedView(product: product)
      } else {
        AgentDockEmptyState(
          title: "Choose a Profile",
          systemImage: "slider.horizontal.3",
          description: "Select a profile to manage its local configuration."
        )
      }
    }
  }
}

private struct ProfileAdvancedView: View {
  @EnvironmentObject private var model: CodexerModel
  let profile: CodexProfile

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        header
        providerApp
        localData
        shortcut
        if profile.product == .codex {
          connection
        }
        management
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }

  private var header: some View {
    HStack(spacing: 16) {
      ProfileIconView(profile: profile, size: 52)
      VStack(alignment: .leading, spacing: 4) {
        Text(profile.name)
          .font(.system(size: 24, weight: .semibold))
        HStack(spacing: 8) {
          StatusDot(isRunning: model.instanceStatus(for: profile).isRunning)
          Text(profile.product.displayName)
          Text("·")
          Text(model.instanceStatus(for: profile).isRunning ? "Running" : "Stopped")
        }
        .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        model.showEditProfile = true
      } label: {
        Label("Edit Profile", systemImage: "pencil")
      }
      .buttonStyle(.bordered)
    }
    .frame(minHeight: 64)
    .padding(.bottom, 8)
    .overlay(alignment: .bottom) {
      Divider().overlay(AgentDockPalette.divider)
    }
  }

  private var providerApp: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(title: "Provider App")
      HStack(spacing: 10) {
        ProviderIconView(
          product: profile.product,
          appURL: model.appURL(for: profile.product),
          size: 28
        )
        VStack(alignment: .leading, spacing: 2) {
          Text("\(profile.product.displayName).app")
            .fontWeight(.medium)
          HStack(spacing: 8) {
            Text(appVersion)
            Text(appExists ? "Found" : "Not Found")
              .foregroundStyle(appExists ? .green : .orange)
              .padding(.horizontal, 7)
              .padding(.vertical, 2)
              .background(.green.opacity(0.12), in: .capsule)
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        Spacer()
        Text(abbreviatedPath(model.appURL(for: profile.product)))
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Button("Change…") {
          model.chooseApp(profile.product)
        }
        .buttonStyle(.bordered)
      }
      .padding(.horizontal, 12)
      .frame(minHeight: 48)
      .background(AgentDockPalette.panel.opacity(0.48), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(AgentDockPalette.panelBorder)
      }
    }
  }

  private var localData: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(title: "Local Data")
      VStack(spacing: 0) {
        HStack(spacing: 10) {
          Image(systemName: "internaldrive")
            .foregroundStyle(.secondary)
            .frame(width: 20)
          Text("Stored locally")
            .fontWeight(.medium)
          Spacer()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)

        Divider().overlay(AgentDockPalette.divider)
        ManagedPathRow(
          title: "Profile Data",
          url: profile.profileDirectory,
          value: {
            let stats = model.stats(for: profile)
            let formatted = ByteCountFormatter.agentDock.string(fromByteCount: stats.dataBytes)
            return stats.dataSizeIsTruncated ? "At least \(formatted)" : formatted
          }()
        )

        if profile.product == .codex {
          Divider().overlay(AgentDockPalette.divider)
          ManagedPathRow(title: "Codex Home", url: profile.codexHomePath)
          Divider().overlay(AgentDockPalette.divider)
          ManagedPathRow(title: "App Data", url: profile.electronUserDataPath)
        } else {
          Divider().overlay(AgentDockPalette.divider)
          ManagedPathRow(title: "User Data", url: profile.claudeUserDataPath)
        }
      }
      .background(AgentDockPalette.panel.opacity(0.48), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(AgentDockPalette.panelBorder)
      }
    }
  }

  private var shortcut: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(title: "Shortcut")
      HStack(spacing: 10) {
        Image(systemName: "arrow.up.forward.app")
          .foregroundStyle(.secondary)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.shortcutExists(for: profile) ? "Installed in Applications" : "Not installed")
          Text(profile.shortcutPath.lastPathComponent)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if model.shortcutExists(for: profile) {
          StatusDot(isRunning: true)
        }
        Spacer()
        if model.shortcutExists(for: profile) {
          Button("Reveal") {
            model.revealShortcut(profile)
          }
          .buttonStyle(.bordered)
          Button("Remove Shortcut", role: .destructive) {
            model.removeShortcut(profile)
          }
          .buttonStyle(.bordered)
        } else {
          Button("Install Shortcut") {
            model.installShortcut(profile)
          }
          .buttonStyle(.borderedProminent)
        }
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .background(AgentDockPalette.panel.opacity(0.48), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(AgentDockPalette.panelBorder)
      }
    }
  }

  private var connection: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(title: "Connection")
      HStack(spacing: 10) {
        Image(systemName: "link")
          .foregroundStyle(.secondary)
          .frame(width: 20)
        Text("OAuth Callback Port")
        Text(profile.mcpOAuthCallbackPort.formatted())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Spacer()
        Image(systemName: "lock")
          .foregroundStyle(.secondary)
        Text("Reserved for this profile")
      }
      .padding(.horizontal, 16)
      .frame(minHeight: 48)
      .background(AgentDockPalette.panel.opacity(0.48), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(AgentDockPalette.panelBorder)
      }
    }
  }

  private var management: some View {
    VStack(alignment: .leading, spacing: 7) {
      SectionLabel(title: "Profile Management")
      VStack(spacing: 0) {
        ManagementButton(
          icon: "pencil",
          title: "Edit Profile",
          subtitle: nil
        ) {
          model.showEditProfile = true
        }
        Divider().overlay(AgentDockPalette.divider)
        ManagementButton(
          icon: "trash",
          title: "Remove Profile…",
          subtitle: "Preserves local data"
        ) {
          model.confirmRemoveProfile(profile)
        }
        Divider().overlay(AgentDockPalette.divider)
        ManagementButton(
          icon: "trash.fill",
          title: "Delete Profile Data…",
          subtitle: "Permanently deletes managed sessions and settings; shared Keychain items remain.",
          destructive: true
        ) {
          model.pendingDeleteProfile = profile
        }
      }
      .background(AgentDockPalette.panel.opacity(0.48), in: .rect(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(AgentDockPalette.panelBorder)
      }
    }
  }

  private var appVersion: String {
    let bundle = Bundle(url: model.appURL(for: profile.product))
    let version = bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    return "Version \(version ?? "Unknown")"
  }

  private var appExists: Bool {
    FileManager.default.fileExists(atPath: model.appURL(for: profile.product).path)
  }

  private func abbreviatedPath(_ url: URL) -> String {
    url.path.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path,
      with: "~"
    )
  }
}

private struct OfficialAdvancedView: View {
  @EnvironmentObject private var model: CodexerModel
  let product: DesktopProduct

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 14) {
          ProviderIconView(product: product, appURL: model.appURL(for: product), size: 48)
          VStack(alignment: .leading, spacing: 4) {
            Text("Official \(product.displayName)")
              .font(.title2.weight(.semibold))
            Text("Default installation")
              .foregroundStyle(.secondary)
          }
          Spacer()
          Button("Change App…") {
            model.chooseApp(product)
          }
        }
        Divider().overlay(AgentDockPalette.divider)
        ManagedPathRow(
          title: "\(product.displayName).app",
          url: model.appURL(for: product)
        )
      }
      .padding(.horizontal, 24)
      .padding(.vertical, 20)
      .frame(maxWidth: 1100, alignment: .leading)
      .frame(maxWidth: .infinity)
    }
  }
}

private struct ManagedPathRow: View {
  @EnvironmentObject private var model: CodexerModel
  let title: String
  let url: URL
  var value: String?

  var body: some View {
    HStack(spacing: 12) {
      Text(title)
        .frame(width: 160, alignment: .leading)
      Text(value ?? abbreviatedPath)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
      Spacer()
      Button("Reveal") {
        NSWorkspace.shared.activateFileViewerSelecting([url])
      }
      .buttonStyle(.bordered)
      Button("Copy") {
        model.copyPath(url)
      }
      .buttonStyle(.bordered)
    }
    .padding(.horizontal, 16)
    .frame(minHeight: 44)
    .accessibilityElement(children: .contain)
  }

  private var abbreviatedPath: String {
    url.path.replacingOccurrences(
      of: FileManager.default.homeDirectoryForCurrentUser.path,
      with: "~"
    )
  }
}

private struct ManagementButton: View {
  let icon: String
  let title: String
  let subtitle: String?
  var destructive = false
  let action: () -> Void

  var body: some View {
    Button(role: destructive ? .destructive : nil, action: action) {
      HStack(spacing: 10) {
        Image(systemName: icon)
          .frame(width: 20)
        VStack(alignment: .leading, spacing: 2) {
          Text(title)
          if let subtitle {
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Spacer()
        Image(systemName: "chevron.right")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .frame(minHeight: subtitle == nil ? 44 : 52)
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .foregroundStyle(destructive ? .red : .primary)
  }
}
