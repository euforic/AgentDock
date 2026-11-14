# Security and Privacy

## Trust Model

AgentDock coordinates local provider applications. It does not make an
untrusted provider process safe and is not an operating-system sandbox.

Security-sensitive operations validate:

- expected provider bundle identifiers and publisher signing teams;
- code signatures and executable paths;
- exact managed profile roots and ownership markers;
- process ancestry, PIDs, and profile arguments;
- path containment and symlink rejection;
- bounded file counts, bytes, subprocess output, read-only provider database
  queries, and shared session readers.

If those checks fail, managed launch, focus, close, restore, delete, or
local activity reads fail closed.

These boundaries are implemented in
[DesktopAppRegistry.swift](../Sources/AgentDockCore/DesktopAppRegistry.swift),
[DesktopInstanceController.swift](../Sources/AgentDockCore/DesktopInstanceController.swift),
[ProfileStore.swift](../Sources/AgentDockCore/ProfileStore.swift), and
[LocalChatSession.swift](../Sources/AgentDockCore/LocalChatSession.swift).

## Shared Host Resources

Managed profiles retain access to normal user resources, including:

- files and project directories;
- shell environment and developer tools;
- network;
- Keychain;
- Git and SSH configuration;
- macOS permissions and provider updater state.

Use separate macOS accounts or stronger operating-system isolation when those
resources must not be shared.

## Local Data

AgentDock stores profile metadata under
`~/Library/Application Support/AgentDock/`. New shortcuts live under
`~/Applications/AgentDock/`.

Older versions may have left session indexes with bounded titles, previews,
timestamps, provider metadata, and relative source paths. They contain no full
transcript bodies, tool output, or absolute working directories. The app no
longer creates browser indexes; explicit profile removal or deletion cleans up
that profile's legacy indexes. Claude activity summaries still scan validated
supported local session sources and cache summaries in memory. AgentDock has no chat browser or
transcript-copying action; removing that UI does not remove activity-source reads.

AgentDock does not provide cloud synchronization, scrape browser cookies, or
read ordinary web-chat caches.

Custom Codex usage refresh is a separate provider egress boundary. AgentDock
reads only the active provider id and its matching provider definition from a
bounded, regular, non-symlink `config.toml`. Custom usage requests permit HTTPS
or loopback-only HTTP, reject URL credentials and unsafe schemes, and allow
redirects only within the same safe origin. Configured header values,
environment-backed values, and bearer tokens exist only on the request; they
are not persisted, logged, surfaced in raw errors, or included in analytics.
Responses are time- and size-bounded. A failed custom-provider request fails
closed instead of exposing the profile's unrelated OpenAI account quota.

Provider launches discard inherited app-profile, app-server routing, and
Electron/Node runtime overrides before supplying the selected profile's paths.
Managed Codex launches pin both `CODEX_HOME` and
`CODEX_ELECTRON_USER_DATA_PATH`, as well as the matching `--user-data-dir`.
The Electron variable also activates the installed app's preservation of
`CODEX_HOME` across its login-shell environment reload. Stock launches clear
managed profile selectors. Managed Claude launches also pair their verified
`CLAUDE_USER_DATA_DIR` override with a matching `--user-data-dir` argument,
covering Chromium session storage from process startup.

The native OpenAI quota reader additionally removes inherited account, API
credential, and endpoint overrides so they cannot redirect the selected
account's usage request. Custom-provider usage requests retain the explicit
environment-backed authentication configured for that provider.

Ordinary shell variables and shared shell startup files remain host resources.
The provider can reload that shell environment after startup; launch-time
sanitization is not an operating-system enforcement boundary.

Provider namespace directories cannot be registered as individual profiles or
replayed as profile deletions. Persisted shortcuts must be distinct `.app`
paths whose normalized name matches the owning profile slug. Recovery journals
cannot claim another profile's directory or shortcut.
Process discovery rejects ambiguous profile arguments and bundle-prefix
lookalikes. Claude helper evidence also requires a publisher signature and a
kernel-resolved executable contained by the selected app bundle before
lifecycle operations revalidate stable process identity. Profile
locks resolve path aliases to one physical root and reject symlinked,
nonregular, multiply linked, or foreign-owned lock files.

Built-in Codex launches set
`CODEX_CLI_PATH` to the validated Codex app's bundled
`Contents/Resources/codex` executable. Named config-profile launches point it
to AgentDock's signed proxy, which validates the profile-local bounded regular
`<name>.config.toml`, converts its assignments to `--config` arguments accepted
by the desktop app-server, and then executes that same bundled CLI. Managed
named-profile launches set the managed profile's exact `CODEX_HOME`; official
named-profile launches set `~/.codex`; built-in stock launches remove
`CODEX_HOME`. User-selected executables cannot replace the bundled CLI through
AgentDock's parent environment. Settings that would place bearer tokens, API
keys, or direct HTTP headers in process arguments are rejected; custom
providers should reference credentials through environment-backed settings.

## Product Analytics

Analytics are a separate explicit-opt-in, immediately revocable boundary implemented in
[`ProductAnalytics.swift`](../Sources/AgentDockCore/ProductAnalytics.swift).
Only closed typed events can be batched to the configured regional PostHog
endpoint. Events never carry source content or local identifiers; GeoIP and
person-profile processing are disabled, and queues exist only in bounded
memory. Explicit choices persist across upgrades; opt-out clears the queue and
random identifier. The public project
token is release configuration, not a credential; no private PostHog key
belongs in the app. See the [complete catalog](analytics.md).

Local Claude usage summaries do not require credentials. Live subscription
limits are an explicit provider-access boundary: AgentDock reads Claude Desktop
OAuth access tokens and the active Desktop organization from provider-owned
Keychain and local state, then calls Anthropic's OAuth profile and usage
endpoints. Desktop and managed Desktop tokens are held only for the request;
AgentDock never copies them into its own storage, refreshes or rotates them,
includes them in analytics, or logs them. The Desktop decryption key is retained only in memory
for the usage client's lifetime and reused across official and managed profiles.
Each profile's tokens and account identity are still read afresh from its files.
Background reads forbid Keychain interaction, including legacy login-Keychain
prompts. A manual refresh can request access; choosing **Always Allow** lets
macOS retain that grant for subsequent launches of the signed app. Managed profiles resolve credentials
only from their own Desktop user-data roots. The official Claude Desktop usage
row still uses Desktop credentials exclusively, so AgentDock's separate Claude
sign-in cannot replace the displayed Desktop account. Desktop usage requires a valid
account and organization identity, and responses are verified against that
identity before display. An explicit identity mismatch clears the corresponding
cached quota instead of showing stale data. Active-organization cookie database
reads run in process through the read-only database reader and enforce the same
root containment and symlink checks as other databases.

## Claude Sign-In for Claude Code Limits

Each Claude profile's Claude Code section uses that profile's own AgentDock
Claude sign-in, not Claude Code's login. Official Claude is the default
profile and has its own. A profile's **Sign In to Claude…** runs a one-time
OAuth authorization code flow with PKCE (S256) through
`claude.ai/oauth/authorize`, using Claude Code's public client ID and the
scopes `user:profile user:inference`. The code is exchanged at
`platform.claude.com/v1/oauth/token`, and the account is read once from
`api.anthropic.com/api/oauth/profile`. Sign-ins are added only this way, by the
user, or by migrating AgentDock's own earlier items; AgentDock never discovers
or imports accounts from other apps.

- `user:inference` lets the token run Claude on the user's plan. AgentDock
  only ever calls the OAuth profile and usage endpoints with it.
- The callback listener binds to 127.0.0.1 on a system-assigned port and
  ignores requests whose `state` does not match. A pasted `code#state` or
  callback URL is checked against the same `state`.
- Each profile's tokens, account and organization UUIDs, email label, plan,
  optional user-chosen name, and added date are stored only in that profile's
  own AgentDock Keychain item in the login Keychain: service
  `dev.euforic.agentdock.claude-login`, account
  `claude-code-profile:<profile key>`, where the key is `official` or the
  managed profile's lowercased UUID, so item names never carry account
  identifiers or the email. Items are not synchronizable. One item per profile
  means a profile can never hold two sign-ins, and no separate mapping file can
  drift from the Keychain. Nothing about these sign-ins is kept in preferences
  or `profiles.json`.
- Signing a profile in again replaces only that profile's item; no duplicate
  is created and no other profile's item is touched, even one signed in to the
  same account.
- Listing reads only the attributes of items under AgentDock's own service.
- Background reads and writes forbid Keychain interaction. Only Sign In,
  Rename, Sign Out, removing a profile, removing unlinked sign-ins, and a
  manual refresh can prompt, and a manual refresh prompts only when an ad-hoc
  rebuild changed the code signature.
- Tokens are renewed five minutes before expiry and written back to that
  profile's item only. Only one renewal per sign-in runs at a time.
- A 401 renews the token once and retries once. A second 401, or a renewal
  Claude refuses (`invalid_grant` or a refresh-token refusal), signs that
  profile out and deletes its item; its card asks for a new sign-in. An outage
  or a rate limit keeps the current token and retries on the next refresh.
  Other profiles are never affected.
- **Sign Out** deletes only that profile's item, plus any item an earlier
  version left for the same account, so migration cannot bring it back.
  Removing a Claude profile from AgentDock or deleting its data deletes its
  item; each launch also deletes items of managed profiles that no longer
  exist.
- Items earlier versions wrote (`claude-code:<account key>` and the single
  `claude-code`) are placed on profiles once per launch. Matching uses only
  AgentDock's own stored name and email and the profile names; the new item is
  written and read back before the old item is deleted, and any failure keeps
  the old item for the next launch. Sign-ins that no profile can take are kept
  untouched until placed or removed by the user. An unreadable old item is left
  untouched. See [Upgrade migration](upgrade-migration.md#claude-code-sign-ins).
- Tokens, authorization codes, and the PKCE verifier are never logged or sent
  to analytics, and Claude Code results are not sent to analytics.
- For limits, AgentDock never reads Claude Code's `Claude Code-credentials`
  Keychain item, `~/.claude/.credentials.json`, `~/.claude.json`, or
  `CLAUDE_CONFIG_DIR`.

Provider 429 cooldowns persist in AgentDock's preferences domain as SHA-256
digests of the projection plus the account and organization identity (the
token digest when there is no identity), mapped to expiry timestamps. They hold
at most 32 entries and 16 KiB and are capped at one hour. They never contain
tokens, raw identifiers, or paths, and restoring default preferences does not
clear them. Because the digest depends only on the account identity, each
Claude account has its own cooldown, shared by every profile signed in to it,
and a cooldown saved before sign-ins moved onto profiles still applies after
migration. The per-account hourly budget of 30 Claude Code usage fetches is
kept in memory only.

## Repository and Release Hygiene

Do not commit:

- credentials, tokens, certificates, provisioning profiles, or environment
  files;
- provider profiles, chats, transcript exports, logs, databases, crash reports,
  or generated indexes;
- screenshots containing real account, project, device, or session data;
- build products or notarization material.

The [release workflow](../.github/workflows/release.yml) uses ephemeral
credentials, removes temporary keychains and key files, rejects filesystem
metadata sidecars and build paths, and publishes checksums for the notarized
artifacts.

Sparkle updates require HTTPS, a Developer ID signature, notarization, and an
Ed25519 signature. The public verification key is embedded in AgentDock. The
private key exists only as the environment-protected
`SPARKLE_PRIVATE_ED_KEY` GitHub Actions secret and is streamed to Sparkle's
tool over standard input. Release assets are published before the signed
appcast, so a client cannot discover an enclosure that is not yet available.

## Reporting a Vulnerability

Follow the [security policy](../SECURITY.md). Use a private GitHub security
advisory instead of a public issue when a report could expose a vulnerability,
credential, private transcript, or local path.
## Publication privacy

Publish only synthetic account/profile examples and anonymous measurement counts.
Never include local hardware or installed-version inventories, home paths,
provider account details, real chats, logs, credentials, or private profile names
in commits, PR descriptions, comments, or their edit history. Use a public GitHub
noreply address for commit author and committer identities.

`script/audit_privacy.sh` scans every locally reachable Git ref for secrets and
checks new commit identities and the measurement receipt schema. Run
`python3 script/audit_publication_metadata.py --all-history` to audit identities
throughout reachable history. Historical violations need coordinated cleanup;
a clean current tree does not remove earlier commits or PR revisions. Review PR
descriptions and edit history separately from the source scan.

## Upgrade migration

The [legacy-folder migration](upgrade-migration.md) takes the store and profile
locks, checks for open files and running managers, validates ownership and
containment, and never merges conflicting stores. It copies only the exact
path-derived Codex Keychain entries needed by the moved profile, preserving
the original entries and their access controls. Keychain credential bytes stay in
memory and the Keychain; they never enter journals or logs. Existing on-disk
profile files are preserved in verified recovery copies inside owner-only backup
directories before mutation. Backups remain after completion and contain private
profile data; they must never be attached to public bug reports. Missing encryption keys, denied
Keychain access, or different destination credentials stop the move. Tests use
synthetic credentials in a temporary isolated Keychain.
