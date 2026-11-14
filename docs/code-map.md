# Code Map

## Package and Entry Points

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift package products, targets, dependencies, and macOS deployment target |
| `Sources/AgentDock/AgentDockApp.swift` | Main SwiftUI app entry point |
| `Sources/AgentDock/AppUpdater.swift` | Sparkle update session, sidebar presentation state, and user-controlled settings |
| `Sources/AgentDock/AgentDockModel.swift` | UI state, profile operations, activity, and quota refreshes |
| `Sources/AgentDock/ContentView.swift` | Main application shell and navigation |
| `Sources/AgentDockShortcutLauncher/main.swift` | Generated shortcut helper entry point |
| `Sources/TranscriptRendererShowcase/TranscriptRendererShowcase.swift` | Synthetic visual-acceptance transcript |

## Core Boundaries

| Path | Responsibility |
| --- | --- |
| `Sources/AgentDockCore/ProfileStore.swift` | Profile persistence, ownership, restore, removal, and deletion |
| `Sources/AgentDockCore/CodexLauncher.swift` | Codex app validation and managed process lifecycle |
| `Sources/AgentDockCore/ClaudeLauncher.swift` | Claude app validation and managed process lifecycle |
| `Sources/AgentDockCore/DesktopAppRegistry.swift` | Official app identities and provider launch contracts |
| `Sources/AgentDockCore/LocalChatSession.swift` | Bounded Claude session readers for activity summaries and legacy chat-index cleanup |
| `Sources/AgentDockCore/BoundedSubprocess.swift` | Timeout and output-bounded subprocess execution |
| `Sources/AgentDockCore/ShortcutInstaller.swift` | Profile shortcut generation and replacement |
| `Sources/AgentDockCore/SQLiteReadOnly.swift` | Path-checked, read-only, no-follow, bounded in-process provider database queries |
| `Sources/AgentDockCore/ClaudeHTTPTransport.swift` | Bounded HTTP transport seam and shared Anthropic OAuth API request headers |
| `Sources/AgentDockCore/ClaudeOAuth.swift` | Claude sign-in protocol: PKCE, authorize URL, code exchange and refresh requests, pasted-code parsing, renewal classification |
| `Sources/AgentDockCore/ClaudeLoopbackCallbackServer.swift` | One-shot 127.0.0.1 OAuth callback listener with a `state` check |
| `Sources/AgentDockCore/ClaudeLoginStore.swift` | AgentDock's Claude sign-in tokens, profile IDs and account keys, and the non-prompting per-profile Keychain items (plus the earlier per-account and single items, read to migrate them) |
| `Sources/AgentDockCore/ClaudeCodeAccounts.swift` | One Claude Code sign-in per Claude profile: listing, the PKCE sign-in flow, per-profile sign-in, rename, and sign-out, removal of missing profiles' sign-ins, migration of earlier items onto profiles, card states, and each state's account controls |
| `Sources/AgentDockCore/ClaudeCodeLogin.swift` | One profile's tokens: the one-account binding enforced at sign-in, single-flight renewal with write-back, rename, sign-out, and Claude Code guidance messages |
| `Sources/AgentDockCore/ClaudeUsageClient.swift` | Live Claude limits for each profile's own Claude Code sign-in: freshness, backoff, 429 cooldowns, hourly budget, throttling, identity verification, and response parsing |
| `Sources/AgentDockCore/ClaudeUsageRateLimitGate.swift` | Saved 429 cooldowns by account identity, identity-verification ledger, per-account hourly budget, cross-account throttle, and per-account exclusion |

## UI and Rendering

| Path | Responsibility |
| --- | --- |
| `Sources/AgentDock/OverviewView.swift` | Profile and official-app overview, including each Claude profile's own Claude Code sign-in card |
| `Sources/AgentDock/ClaudeSignInSheet.swift` | Browser and pasted-code steps of signing one Claude profile in with AgentDock's sign-in |
| `Sources/AgentDock/ActivityDetailView.swift` | Supported local activity details |
| `Sources/TranscriptRenderer/TranscriptModels.swift` | Provider-neutral render model and event classification |
| `Sources/TranscriptRenderer/TranscriptView.swift` | Accessible presentation for the separate renderer showcase and tests |

## Validation and Delivery

- `Tests/AgentDockCoreTests/`: profile, process, scanner, shortcut, and parser
  coverage.
- `Tests/AgentDockAppTests/`: model concurrency, selection, and mutation
  coverage.
- `Tests/TranscriptRendererTests/`: event order, malformed input, capability
  gating, bounded output, and performance.
- `.github/workflows/release.yml`: build, test, signing, notarization, privacy,
  checksum, and release gates.
- `script/build_app.sh`: production app bundle assembly.
- `script/package_app.sh`: ZIP/DMG packaging and artifact privacy checks.

Generated `.build/`, `dist/`, local databases, logs, and profile data are not
source files and must remain untracked.
