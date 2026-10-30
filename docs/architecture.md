# Architecture

AgentDock is a native SwiftUI macOS application with a small Swift package
surface and no application server of its own.

## Components

### App UI

[Sources/AgentDock](../Sources/AgentDock) contains the SwiftUI application, navigation, profile
management, activity views, usage, and reset inventory. `AgentDockModel` owns
UI-facing asynchronous state and suppresses stale refresh results. An invalid
selection never resolves to a different profile. The app does not browse chats
or copy transcripts. See [AgentDockModel.swift](../Sources/AgentDock/AgentDockModel.swift).

[`AppUpdater`](../Sources/AgentDock/AppUpdater.swift) owns the single Sparkle 2
`SPUUpdater` and a user driver that preserves Sparkle's standard interface for
manual checks. Sparkle persists the user's automatic-check and
automatic-download preferences; AgentDock does not create a parallel updater
preference store. Configured release builds ask Sparkle to check once per hour.
The Stable release channel is selected by default. An explicit Settings choice
switches Sparkle to the signed Alpha appcast and channel; switching back restores
the built-in Stable appcast immediately.
Users can change that cadence to every six hours, daily, or weekly in Settings;
Sparkle persists the selected interval and resets its scheduled update cycle.
Unless the user opts into automatic downloads, scheduled discoveries appear as
a persistent Update button at the bottom of the sidebar. Selecting it accepts Sparkle's retained, signed
update session directly: AgentDock shows download and installation progress in
the sidebar while Sparkle performs verification, installation, and relaunch
without first opening its update-choice window.

[`ProductAnalytics`](../Sources/AgentDockCore/ProductAnalytics.swift) is the only
telemetry egress boundary. It owns opt-out gating, identifier lifecycle, typed
schema validation, bounded in-memory batching, and regional HTTPS delivery.
Call sites cannot add arbitrary event names, keys, or string values.

Claude live-usage responses are cached per credential for five minutes.
Concurrent reads for the same credential share one in-flight request, and
failures temporarily suppress automatic retries (including provider-supplied
`Retry-After` values for rate limits). The explicit user refresh action can
bypass freshness and failure cooldowns; navigation, profile launch, and the
automatic activity timer cannot.

Codex usage refresh is provider-aware. The built-in OpenAI provider uses the
bundled Codex app-server, while a selected custom provider uses its configured
`/usage` quota endpoint. Provider configuration parsing, safe URL construction,
request authentication, bounded response reading, and meter translation remain
in `AgentDockCore`; the UI consumes only `ProfileRateLimits`.

### Core

[Sources/AgentDockCore](../Sources/AgentDockCore) owns the security-sensitive boundaries:

- profile persistence and ownership markers;
- official app discovery and signature validation;
- exact process discovery, focus, and termination;
- shortcut creation and validation;
- bounded subprocess execution;
- provider-aware usage retrieval;
- local activity scanning, including bounded Claude session readers;
- profile-specific MCP callback configuration.

Core operations fail closed when a path, process, bundle, signature, ownership
marker, or provider launch contract cannot be verified.

The primary boundaries are implemented by
[ProfileStore.swift](../Sources/AgentDockCore/ProfileStore.swift),
[DesktopAppRegistry.swift](../Sources/AgentDockCore/DesktopAppRegistry.swift),
[DesktopInstanceController.swift](../Sources/AgentDockCore/DesktopInstanceController.swift),
and [LocalChatSession.swift](../Sources/AgentDockCore/LocalChatSession.swift).

### Transcript Renderer

[Sources/TranscriptRenderer](../Sources/TranscriptRenderer) defines a provider-neutral event model and SwiftUI
renderer used by the separate synthetic showcase and renderer tests. The main
AgentDock application does not host transcripts. It preserves source order,
stable row identity, malformed records,
bounded output, and provider capability gating. The renderer does not own chat
discovery, indexing, or storage. Its public model is in
[TranscriptModels.swift](../Sources/TranscriptRenderer/TranscriptModels.swift).

### Shortcut Launcher

[Sources/AgentDockShortcutLauncher](../Sources/AgentDockShortcutLauncher) builds the native helper embedded in generated
profile shortcuts. The helper reads a validated profile configuration and
delegates to the same core launch rules used by the main app through
[ShortcutLauncherRunner.swift](../Sources/AgentDockCore/ShortcutLauncherRunner.swift).
For a selected named Codex config profile, the same signed helper becomes a
bounded CLI proxy: it validates the official app and the profile-local
`<name>.config.toml`, translates its assignments into bounded `--config`
arguments, then executes the app's bundled CLI. User-selected executables are
never part of this contract.
After an AgentDock update, installed shortcuts with an older embedded helper
build are rebuilt through `ShortcutInstaller`'s existing locked, atomic path.
Profile identifiers, ownership markers, configurations, sessions, and other
managed data are not migrated or replaced.

## Isolation Model

Managed Codex profiles receive separate `CODEX_HOME` and Electron user-data
directories, pinned through both the supported Electron environment variable
and its matching command-line argument. Managed Claude profiles receive
separate `UserData` roots through the verified `CLAUDE_USER_DATA_DIR` launch
contract and the matching Chromium `--user-data-dir` argument.

Codex launch-profile selection and its default are account-local metadata for
every managed profile and the official account. `Use Default`, explicit
Built-in Codex, and a named config profile are distinct persisted states, so
changing one account never changes another and changing the default does not
erase an explicit built-in override.

Isolation covers supported provider configuration, authentication state, local
browser state, and profile data. It does not change `HOME` and is not a macOS
sandbox. Filesystem, network, shell, Keychain, Git, SSH, preferences, updater,
and system permission boundaries remain shared unless the provider itself
separates them.

## Process Safety

AgentDock maps a managed profile path to an exact signed main-app process.
Focus and close operations revalidate the bundle, executable, PID, ancestry,
and profile argument immediately before acting. Claude discovery admits only
publisher-signed helpers whose kernel-resolved executable is contained by the
selected app bundle, and binds lifecycle actions to stable process start
identity. Claude checks its startup contract at the start of each operation;
launch and close polling refresh process trust without repeatedly scanning the
ASAR archive. The app signature is checked again immediately before launch.
Codex close also recognizes
signed provider helpers whose executable is contained by that profile's
`CODEX_HOME`, including helpers that no longer carry an Electron profile
argument. Stock app discovery is separate, so a managed action does not target
the normal provider instance or another managed profile.

## Persistence

Profile metadata lives under `~/Library/Application Support/AgentDock/`.
On the first upgrade launch, `LegacyBrandMigration` moves the previous brand's
support and shortcut directories into the AgentDock locations, preserving profile
identities and rebasing only AgentDock-owned metadata. A fixed-location journal
allows a subsequent launch to finish interrupted moves. See
[Upgrade migration](upgrade-migration.md) for safety and recovery behavior.

See [Data flows](data-flows.md) for lifecycle sequences and
[Security and privacy](security.md) for trust boundaries.
