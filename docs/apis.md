# Interfaces and Contracts

AgentDock does not expose a network service or public HTTP API. Its stable
interfaces are Swift package products, local process contracts, persisted
formats, and release scripts.

## Swift Package Products

`Package.swift` declares:

- `AgentDock`: the macOS app executable.
- `AgentDockShortcutLauncher`: the generated shortcut helper.
- `TranscriptRendererShowcase`: the synthetic renderer showcase.
- `AgentDockCore`: profile, process, scanner, and shortcut logic.
- `TranscriptRenderer`: provider-neutral transcript models and views.

The two library products are integration surfaces inside this repository. They
do not carry a semantic-versioning compatibility promise independent of the app.

`DesktopInstanceController.statusBatch(for:appURLs:)` inspects managed and
official instances together. Each available selected provider captures one
bounded process snapshot. A missing or nonexecutable Codex app returns stopped
statuses without inspecting processes. Claude's strict app signature and startup-contract checks
run once per batch, and each candidate main process still requires its dynamic
publisher identity check. Validation is repeated on the next batch; no bundle
modification-time cache replaces signature or contract validation.

Status reads (`statusBatch`, `statuses`, `stockStatus`, and Claude's
`status(for:appURL:)`, which wraps `statuses`) await their `ps` snapshot. The
wait suspends instead of holding a cooperative thread, and reads on one provider
controller can overlap. They change no controller state. Claude's helper and
main-process identity checks, with their kernel start-key comparisons, run
after the snapshot returns and before the next suspension point. Open, close,
and focus flows keep synchronous snapshots, so no other work on that controller
runs between a lifecycle snapshot and the identity checks and signals that act
on it. A status result never authorizes a lifecycle action; each action takes
its own snapshot.

An unselected or failed provider contributes no entries. Callers retain the
last successful status for that provider and remove entries for deleted
profiles. A cancelled batch returns no entries, and callers must check task
cancellation before applying results. Individual managed and official status
APIs remain available for lifecycle operations.

## Provider Launch Contracts

Codex profiles use:

```text
CODEX_HOME=<profile>/CODEX_HOME
CODEX_ELECTRON_USER_DATA_PATH=<profile>/ElectronUserData
--user-data-dir=<profile>/ElectronUserData
[generated] --config <dotted-key=toml-value> ... app-server
```

Named profiles are discovered from an account's own
`CODEX_HOME/<name>.config.toml` files. AgentDock stores whether each managed
profile and the official account use their own default, force the built-in
configuration, or select one named profile. The launch helper reads only the
selected profile file and translates its bounded TOML assignments into
app-server-supported `--config` overrides while keeping
`CODEX_CLI_PATH` pinned to AgentDock's bundled proxy and, ultimately, the CLI
bundled inside the validated Codex app. Codex's `--profile` flag is not used
because the desktop app-server command rejects it.

Claude profiles use:

```text
CLAUDE_USER_DATA_DIR=<profile>/UserData
--user-data-dir=<profile>/UserData
```

Claude launches proceed only when the installed signed app still exposes the
verified early environment-variable and `app.setPath` behavior. The matching
argument also pins Chromium session storage from process startup. The signed
app and exact process/root attribution remain mandatory; the argument alone
is not evidence of a supported isolation contract.

## Persistent Formats

- `profiles.json`: AgentDock-owned profile metadata. Array order preserves the
  user-defined managed-profile order within each provider section.
- `.agentdock-profile.json`: binds a managed directory to its persisted profile.
  Legacy ownership markers are validated before conversion.
- `.agentdock-locks`: per-profile advisory locks; existing legacy lock inodes are
  also acquired while older shortcuts may still exist.
- Upgrade journal and completion marker: see [Upgrade migration](upgrade-migration.md).
- Shortcut configuration plist: binds a generated shortcut to one provider,
  profile root, and ownership identity.
- Startup preference: Home, Last Opened Profile, or Overview. A stored legacy
  `AgentDock.defaultView = "chats"` migrates to `"overview"` without changing
  other preferences.
- Legacy chat indexes: versioned, bounded summary metadata with relative
  source paths and a source-root fingerprint, left by older versions. AgentDock
  no longer reads or writes these indexes; explicit profile removal or deletion
  deletes that profile's legacy index files. Claude activity summaries remain
  in memory.
- Analytics state: `undecided`, `denied`, or `granted` in UserDefaults. The
  analytics boundary never promotes `undecided` without a user action. A random
  installation UUID exists only while granted and is deleted on opt-out;
  explicit choices persist across launches and upgrades.

Readers validate containment, type, ownership, and size before using persisted
paths or provider records.

Codex usage resolution follows the active user-level provider configuration:

- An omitted `model_provider`, or `model_provider = "openai"`, uses the bundled
  Codex app-server's `account/rateLimits/read` method.
- A selected custom provider with a matching
  `model_providers.<id>.base_url` uses `GET <base_url>/usage`. AgentDock applies
  configured static headers, environment-backed headers, bearer-token
  environment keys, and query parameters without persisting or logging their
  values.
- A selected non-OpenAI provider without a usable custom-provider definition
  reports usage as unavailable. It does not fall back to an unrelated OpenAI
  account limit.
- A present but unsupported `model_provider` value, or an unsafe configuration
  file, also reports usage as unavailable. Missing and malformed configuration
  are not interchangeable.

The quota response is a normalized meter document containing an optional plan
and `meters`. Each meter may provide `id`, `label`, `used_percent`,
`window_seconds`, `resets_at`, and optional amount fields. AgentDock validates
counts and numeric ranges before mapping those values into `ProfileRateLimits`;
a `credits` meter maps its remaining amount into the existing credit display.

Claude activity and token summaries for official installations and managed
profiles are derived at runtime from validated local Cowork audit records and
are not a new persisted format. Both source types expose the same summary
contract, including model mix, token coverage, and the latest locally emitted
rate-limit event. Coverage prevents partially available token data from being
mistaken for complete usage.

Live Claude limits use `GET https://api.anthropic.com/api/oauth/usage` with the
selected provider login's in-memory access token. The response maps five-hour,
weekly, model-scoped, reset, and extra-usage fields into `ProfileRateLimits`.
AgentDock verifies account and organization identity through the sibling OAuth
profile endpoint before assigning a response to an account-scoped source. It
does not persist, rotate, refresh, or log provider credentials. The exception is
AgentDock's own Claude sign-ins for each Claude profile's Claude Code section,
described below, whose tokens AgentDock stores and renews, one Keychain item
per profile.

### AgentDock Claude sign-in

The sign-in uses Claude's public OAuth protocol with Claude Code's public
client ID `9d1c250a-e61b-44d9-88ed-5944d1962f5e`.

- **Authorize:** `https://claude.ai/oauth/authorize` with, in order,
  `client_id`, `response_type=code`, `redirect_uri`
  (`http://localhost:<port>/callback`), `scope=user:profile user:inference`,
  `code_challenge`, `code_challenge_method=S256`, `state`, and `code=true`.
- **Exchange:** `POST https://platform.claude.com/v1/oauth/token` with only
  `Content-Type: application/json` and the body `grant_type=authorization_code`,
  `client_id`, `code`, `state`, `redirect_uri`, and `code_verifier`. A pasted
  code sends the same body, including the loopback `redirect_uri`.
- **Refresh:** the same endpoint with `grant_type=refresh_token`,
  `refresh_token`, `client_id`, and `scope=user:profile user:inference`. A 400
  with `invalid_scope` is retried once with `scope=user:profile`.
- **Refusal:** a 400, 401, or 403 whose error code (`error`, `error.code`, or a
  top-level `code`) is `invalid_grant`, `refresh_token_expired`,
  `refresh_token_reused`, or `refresh_token_invalidated` ends the sign-in. Any
  other failure, including 429, 5xx, malformed JSON, or an empty
  `access_token`, keeps the current token and is retried on the next refresh.
- **Profile:** `GET https://api.anthropic.com/api/oauth/profile` supplies
  `account.uuid`, `account.email` (or a top-level `email`),
  `organization.uuid`, and `organization.organization_type` without its
  `claude_` prefix as the plan.
- **Profile item:** each Claude profile's sign-in is the generic password
  `claude-code-profile:<profile key>` under the service
  `dev.euforic.agentdock.claude-login`, where the profile key is `official`
  (Official Claude, the default profile) or the managed profile's lowercased
  UUID. It holds whichever account the profile signed in with; signing that
  profile in again replaces only it.
- **Account key:** the first 16 bytes of
  `SHA-256("agentdock.claude-login|<account uuid>|<organization uuid>")`
  (lowercased UUIDs) as 32 lowercase hex characters. It identifies the account
  for its rate-limit state and cache, and names the per-account items earlier
  versions wrote, `claude-code:<account key>`, which are read only to migrate
  them onto profiles.
- **Stored payload:** JSON with `version`, `accessToken`, `refreshToken`,
  `expiresAt` (seconds since 1970), `scopes`, `accountUUID`,
  `organizationUUID`, `accountLabel`, `subscriptionType`, and the optional
  `customName` and `addedAt`. Payloads without the optional fields, written by
  earlier versions, still load.

The Claude Code section uses a separate projection of the same response. It
maps only `five_hour` (5-hour, absent when null), `seven_day` (Weekly), and
Fable's weekly percentage, with no other model rows and no extra usage. Fable
comes from `limits[]` entries whose `kind` is `weekly_scoped`, whose `group` is
missing, null, or `weekly`, whose `percent` is a non-negative JSON number (not a
boolean or string), and whose `scope.model` is Fable: an `id` containing
`fable`, or a trimmed `display_name` equal to `Fable` or starting with
`Fable ` (case-insensitive). The highest matching percentage wins, with its
`resets_at`. Without a matching entry, the legacy `seven_day_fable` window is
used. The Desktop projection is unchanged.

A 429 from the usage or profile endpoint honors `Retry-After` as delta seconds
or an HTTP-date (`Wed, 21 Oct 2099 07:28:00 GMT`). The cooldown is at least
60 seconds, defaults to five minutes, and is capped at one hour.

## Build and Release Environment

The build scripts accept namespaced environment variables including:

- `AGENTDOCK_VERSION`
- `AGENTDOCK_BUILD_NUMBER`
- `AGENTDOCK_SIGNING_IDENTITY`
- `AGENTDOCK_SIGNING_KEYCHAIN`
- `AGENTDOCK_NOTARY_KEY_PATH`
- `AGENTDOCK_NOTARY_KEY_ID`
- `AGENTDOCK_NOTARY_ISSUER_ID`
- `AGENTDOCK_POSTHOG_PROJECT_TOKEN` (public `phc_` project token only)
- `AGENTDOCK_POSTHOG_HOST` (`https://us.i.posthog.com` or
  `https://eu.i.posthog.com`)

Notarization variables must be supplied together. Release credentials belong in
GitHub Actions secrets or an ephemeral local process environment, never in
tracked files.

## MCP Callback Configuration

Managed Codex profiles reserve a unique localhost callback port and retain
profile-local OAuth credential storage settings. AgentDock does not route the
shared provider URL scheme between simultaneous instances.

Compatibility validation runs the selected Codex bundle against the exact
profile config through an isolated temporary home. It does not load or refresh
the profile's account credentials, so expired authentication cannot be
misreported as an invalid config.
