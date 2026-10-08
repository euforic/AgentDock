# Code Map

## Package and Entry Points

| Path | Responsibility |
| --- | --- |
| `Package.swift` | Swift package products, targets, dependencies, and macOS deployment target |
| `Sources/Codexer/CodexerApp.swift` | Main SwiftUI app entry point |
| `Sources/Codexer/AppUpdater.swift` | Sparkle update session, sidebar presentation state, and user-controlled settings |
| `Sources/Codexer/CodexerModel.swift` | UI state, profile operations, activity, and quota refreshes |
| `Sources/Codexer/ContentView.swift` | Main application shell and navigation |
| `Sources/CodexerShortcutLauncher/main.swift` | Generated shortcut helper entry point |
| `Sources/TranscriptRendererShowcase/TranscriptRendererShowcase.swift` | Synthetic visual-acceptance transcript |

## Core Boundaries

| Path | Responsibility |
| --- | --- |
| `Sources/CodexerCore/ProfileStore.swift` | Profile persistence, ownership, restore, removal, and deletion |
| `Sources/CodexerCore/CodexLauncher.swift` | Codex app validation and managed process lifecycle |
| `Sources/CodexerCore/ClaudeLauncher.swift` | Claude app validation and managed process lifecycle |
| `Sources/CodexerCore/DesktopAppRegistry.swift` | Official app identities and provider launch contracts |
| `Sources/CodexerCore/LocalChatSession.swift` | Shared bounded session readers and indexes, including Claude activity-summary input |
| `Sources/CodexerCore/BoundedSubprocess.swift` | Timeout and output-bounded subprocess execution |
| `Sources/CodexerCore/ShortcutInstaller.swift` | Profile shortcut generation and replacement |

## UI and Rendering

| Path | Responsibility |
| --- | --- |
| `Sources/Codexer/OverviewView.swift` | Profile and official-app overview |
| `Sources/Codexer/ActivityDetailView.swift` | Supported local activity details |
| `Sources/TranscriptRenderer/TranscriptModels.swift` | Provider-neutral render model and event classification |
| `Sources/TranscriptRenderer/TranscriptView.swift` | Accessible presentation for the separate renderer showcase and tests |

## Validation and Delivery

- `Tests/CodexerCoreTests/`: profile, process, scanner, shortcut, and parser
  coverage.
- `Tests/CodexerAppTests/`: model concurrency, selection, and mutation
  coverage.
- `Tests/TranscriptRendererTests/`: event order, malformed input, capability
  gating, bounded output, and performance.
- `.github/workflows/release.yml`: build, test, signing, notarization, privacy,
  checksum, and release gates.
- `script/build_app.sh`: production app bundle assembly.
- `script/package_app.sh`: ZIP/DMG packaging and artifact privacy checks.

Generated `.build/`, `dist/`, local databases, logs, and profile data are not
source files and must remain untracked.
