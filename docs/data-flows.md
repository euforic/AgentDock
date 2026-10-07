# Data Flows

## Create and Launch a Profile

1. The UI requests profile creation through
   [`CodexerModel`](../Sources/Codexer/CodexerModel.swift).
2. [`ProfileStore`](../Sources/CodexerCore/ProfileStore.swift) allocates a provider-scoped slug, directory, ownership marker,
   and persisted profile record under a cross-process lock.
3. The selected launcher validates the official provider bundle and its signing
   identity.
4. Before a new Codex launch, AgentDock closes any provider-signed orphan helper
   whose live executable remains contained by that profile's `CODEX_HOME`.
5. AgentDock resolves the persisted Codex launch selection to that managed
   profile's own default, Built-in Codex, or a safe profile-local
   `<name>.config.toml`. Named profiles are translated into bounded `--config`
   overrides accepted by the desktop app-server command. The official account
   follows the same flow against `~/.codex`.
6. AgentDock starts a new provider instance with the profile-specific local
   state contract.
7. Post-launch discovery verifies the returned process before the UI marks the
   profile as running.

Changing the selection for a running Codex profile closes that exact instance,
persists the new choice, refreshes its shortcut, and reopens it. A missing or
unsafe named profile fails before the running instance is closed.

Failed persistence or validation rolls back partial state where safe. A
destructive delete uses a separate confirmation and fails closed while the
profile is in use.

Removing a profile from the list preserves its ownership identity. Restoring
that managed directory reuses the verified marker identifier, so an existing
profile shortcut remains bound to the same profile.

## Focus and Close

1. [`DesktopInstanceController`](../Sources/CodexerCore/DesktopInstanceController.swift)
   finds candidates carrying the exact managed profile root.
2. AgentDock resolves and validates the signed main process and any
   provider-signed helper executable contained by the selected profile root.
3. Focus activates only that PID.
4. Close sends graceful termination only to verified processes for the selected
   profile, tracks captured descendants by stable process identity, and bounds
   the wait for cleanup.

The stock provider app and other managed profiles do not match the selected
profile path.

## Codex Usage Refresh

1. AgentDock reads the selected profile's bounded, regular, non-symlink
   `CODEX_HOME/config.toml`. A missing `model_provider` means the built-in
   `openai` provider.
2. Native OpenAI profiles retain the signed bundled app-server flow and call
   `account/rateLimits/read` with the selected `CODEX_HOME`.
3. For a selected custom provider, AgentDock resolves the matching
   `model_providers.<id>.base_url` and requests its `<base_url>/usage` quota
   endpoint.
4. HTTPS is accepted. Plain HTTP is accepted only for loopback providers;
   redirects must remain on the same safe origin. Requests and responses are
   time- and size-bounded.
5. Provider headers, environment-backed headers, bearer-token environment
   keys, and query parameters are applied in memory. Their values and response
   bodies are never logged or added to analytics.
6. Returned allowance meters are validated and shown with their percentage
   consumed, window, and reset time. Seven-day windows use the same Weekly
   presentation as native Codex limits.
7. A missing, unsafe, unsupported, or failed custom-provider usage endpoint is
   shown as unavailable for that provider. AgentDock never substitutes native
   OpenAI quota for traffic sent to another provider.

## Local Chat Indexing

Chat inventories, transcript reads, and five-second change checks run only
while Chats is visible and AgentDock is active. Selecting a profile's Overview
does not load its chats. Leaving Chats or switching away from AgentDock cancels
pending chat work; returning to Chats refreshes its list and transcript.
Automatic activity and process-status polling also skip inactive periods.
Native reset reminders continue to operate in the background.

1. [`LocalChatSession`](../Sources/CodexerCore/LocalChatSession.swift) inventories
   only supported provider metadata sources. Codex database rows accelerate
   metadata lookup but are merged with the bounded session-file inventory
   rather than treated as a complete list.
2. The scanner validates source roots, rejects symlinks, bounds file counts and
   bytes, and uses no-follow reads.
3. AgentDock writes a versioned profile-scoped summary index atomically with
   owner-only permissions.
4. The list presents bounded titles, previews, and source metadata.
5. Opening a chat reads a bounded transcript page and converts source events
   into the provider-neutral renderer model.
6. Unsupported source events render as bounded, content-free placeholders;
   malformed records remain visibly distinct.
7. Additional pages append in source order while stable IDs prevent duplicate
   rows and stale chat switches are suppressed.

For official and managed Claude sources, the same validated Cowork audit
sources also feed an in-memory usage summary. Assistant token records are
deduplicated by their message/request identity before aggregation, scans are
byte-bounded and cached by source size and modification time, and model totals
remain source-scoped. The overview uses the same usage and activity components
for both source types and lists the official installation beside managed
accounts for quick comparison and selection.
Claude `rate_limit_event` records contribute only their latest observed status,
bucket, reset time, and optional utilization. Missing utilization stays missing;
AgentDock does not carry an older percentage into a newer limit window.

Live Claude quota refresh is a separate flow:

1. Official Claude prefers a live-capable Claude Code login and falls back to
   the official Desktop OAuth cache. Managed profiles use only their own
   Desktop user-data root.
2. Background refresh reads Keychain without interaction. Manual refresh may
   request access to Claude Safe Storage.
3. The active account and organization are resolved locally and verified with
   Anthropic before the usage response is assigned to a source.
4. Access tokens remain in memory and are never copied, refreshed, persisted,
   or logged by AgentDock.
5. HTTP 429 responses create a credential-scoped cooldown and retain only the
   last successful in-memory snapshot for that same login.

Full transcript bodies and tool output are not stored in the summary index.
Malformed, partial, and unsupported events remain visible instead of silently
disappearing.

## Product Analytics

1. An undecided installation sends nothing and has no analytics identifier.
2. When delivery is configured, the app asks for consent. An explicit grant
   creates a random UUID unrelated to local or provider data; denial exits
   without a payload, network request, or identifier.
3. Call sites submit closed enum events to the single core boundary.
4. The boundary validates properties, adds minimal platform context, disables
   GeoIP/person profiles, and holds at most 48 events in memory.
5. Up to twelve events are sent in a bounded HTTPS batch after at most five
   seconds, with only one active delivery at a time. Failures are dropped
   without persistent retries or raw error logging.
6. Opt-out synchronously purges pending events and deletes the UUID; re-enabling
   creates an unlinkable replacement.

No profile, provider-account, chat, transcript, session, filesystem, command,
configuration, raw error, log, or crash content enters this flow.

## Shortcut Installation

1. AgentDock validates the selected profile and official provider app.
2. [`ShortcutInstaller`](../Sources/CodexerCore/ShortcutInstaller.swift) creates a native helper bundle in a temporary sibling.
3. The shortcut configuration is bound to the profile ownership marker.
4. The completed shortcut atomically replaces the prior bundle under
   `~/Applications/AgentDock/`.

## Release Artifacts

1. A `vMAJOR.MINOR.PATCH` tag starts a Stable release. A successful `Quality`
   run for a push to `main` starts a ten-minute coalescing window, then creates
   and dispatches an immutable Alpha tag for the latest tested revision.
2. Stable releases run the full Swift test suite. Alpha releases reuse the
   successful `Quality` result for the exact tagged commit.
3. A production app is built with hardened runtime and a Developer ID
   signature.
4. Sparkle.framework, its updater helper, and its XPC services are signed from
   the inside out before the outer app is signed.
5. The app and DMG are submitted to Apple notarization and stapled.
6. Gatekeeper, code-signature, DMG integrity, ZIP sidecar, and build-path privacy
   checks run before publication.
7. GitHub Releases receives the ZIP, DMG, and SHA-256 checksum file using
   [package_app.sh](../script/package_app.sh).
8. Only after the immutable release ZIP exists, Sparkle's `generate_appcast`
   signs an enclosure pointing at that tagged asset. The signed appcast is the
   final publication, as `appcast.xml` for Stable or `appcast-alpha.xml` for
   Alpha on the `gh-pages` branch.

No release credential is stored in the repository or packaged artifact.
