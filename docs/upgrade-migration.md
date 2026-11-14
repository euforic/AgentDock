# Upgrade migration

AgentDock uses `AgentDock`, `AgentDockCore`, and `AgentDockShortcutLauncher` for
its Swift modules and products. Build and release overrides use only the
`AGENTDOCK_` prefix.

On the first launch after an upgrade, the default `ProfileStore` automatically
backs up and then moves `~/Library/Application Support/Codexer/` to
`~/Library/Application Support/AgentDock/` and `~/Applications/Codexer/` to
`~/Applications/AgentDock/`. Explicitly supplied test or custom store roots are
never relocated. Existing AgentDock roots still convert legacy ownership and
MCP management markers when loaded. The automatic startup path also backs up
existing AgentDock stores that still have legacy ownership markers. The store
is not exposed to the app until migration and validation succeed.

The migration preserves profile IDs, order, names, icon settings, callback ports,
provider selections, and the entire profile directory tree, including data
removed from the profile list. It rebases the profile and shortcut directories
in `profiles.json`; it does not perform string replacements in provider-owned
configuration, databases, chat content, or user files. User-authored absolute
paths that refer to the previous location may need updating.

Known legacy preferences are copied from the old defaults domain and current
domain into AgentDock keys once. Existing AgentDock choices take precedence.
The original preference values remain available. The app bundle identifier and
Sparkle update feed remain unchanged.

## Credentials and shortcuts

Codex's Keychain account names include a hash of the canonical `CODEX_HOME`
path. Before moving the folders, AgentDock copies matching `Codex Auth` login
entries and `codex` secret-encryption keys to their new account names, preserving
the original entries and their Keychain access controls. macOS may request
Keychain access. A denied read, conflicting destination credential, or encrypted
file without its original key stops migration. Secrets remain in memory and the
Keychain; the journal contains only a version, two move flags, and a backup UUID.

The path-hash contracts come from upstream
[login storage](https://github.com/openai/codex/blob/main/codex-rs/login/src/auth/storage.rs)
and [secret storage](https://github.com/openai/codex/blob/main/codex-rs/secrets/src/lib.rs).
Provider credentials and encrypted files are otherwise unchanged.

On loading migrated profiles, the app automatically rebuilds installed shortcuts
with the current helper and current paths. It checks a storage-format version
and profile binding in addition to the build number. A rebuild failure preserves
the existing shortcut and displays an error; relaunch retries. Dock pins pointing
to the previous shortcut folder may need to be replaced with the migrated shortcut.

## Claude Code sign-ins

AgentDock's own Claude sign-ins for Claude Code limits belong to profiles: each
Claude profile, and Official Claude as the default profile, has at most one,
stored in the generic password `claude-code-profile:<profile key>` under the
service `dev.euforic.agentdock.claude-login`. The profile key is `official` or
the managed profile's lowercased UUID.

Earlier versions stored one item per Claude account (`claude-code:<account
key>`) and, before that, a single `claude-code` item. Once per launch, after the
profile list loads and before any Claude Code usage is fetched,
`ClaudeCodeAccounts.migrateEarlierSignIns` places them on profiles:

- **Matching uses only data AgentDock already has**: the name you gave the
  account in AgentDock and its email, both stored in AgentDock's own item, and
  the profile names in `profiles.json`. A sign-in goes to the first managed
  Claude profile, in sidebar order, whose name equals the sign-in's AgentDock
  name, otherwise to the first whose name equals its email (both ignoring case
  and outer spaces). A sign-in that matches no profile goes to Official Claude.
  AgentDock never reads Claude Code's credentials, `~/.claude`,
  `~/.claude.json`, Claude Desktop data, or another app's Keychain items to
  match.
- **One sign-in per profile.** When several land on the same profile, the one
  added to AgentDock first wins; a missing added date counts as earliest, and
  the lower account key breaks a tie. A profile that already has a sign-in keeps
  it, even one AgentDock can't read: its item still binds the profile until
  **Sign Out**, so migration never overwrites it.
- **Safe moves.** The winner is written to the profile's item, read back and
  compared, and only then is the earlier item deleted. If any step fails, the
  earlier item stays and the next launch retries.
- **Nothing is lost.** Sign-ins that cannot be placed keep their earlier item
  untouched. Official Claude then shows how many were kept, with **Remove** to
  delete them. A kept sign-in is placed on a later launch once a free Claude
  profile matches it, for example a new profile named after its email.
- **Redundant items are removed.** An earlier item whose account is already
  signed in on a profile is deleted, as is a single legacy item whose account
  also has an account-keyed item (the keyed one is newer). Signing a profile out
  also deletes any earlier item of the same account, so it cannot come back.
- **Idempotent.** Running it again with the same profiles changes nothing.
- The same launch removes the items of managed profiles that no longer exist,
  in case removing a profile's sign-in failed earlier.

After upgrading, each profile's existing item becomes its account binding: a
profile already signed in stays with that account, and signing in with another
account is refused until the profile signs out. The item format is unchanged.

## Claude Desktop usage and the Claude Usage Sources list

Earlier versions also showed a "Claude Desktop Usage Limits" card, read from
Claude Desktop's own sign-in, and a "Claude Usage Sources" list on Claude
pages. Both are removed; no migration is needed. The sources list saved no
selection. Desktop usage was cached only in memory, and the 429 cooldowns it
saved under `AgentDock.claudeUsage.rateLimitCooldowns` are never looked up
again and expire within one hour; the store prunes them. Cooldowns of Claude
Code sign-ins keep their keys and still apply.

If reading the Keychain needs a prompt, migration waits and every Claude
profile shows the Keychain notice until a manual Refresh allows it. Persisted
429 cooldowns are keyed by account identity, so they still apply after the
move.

## Safety and recovery

Before recovering old operation journals, changing profile files, or moving either
folder, AgentDock makes a recovery copy under
`~/Library/Application Support/AgentDock Migration Backups/<UUID>/`. `Store/`
contains the complete original storage tree and `Shortcuts/` the original shortcut
tree. This includes hidden files, credential caches, databases, detached profiles,
and pending operation journals. The enclosing backup directories are owner-only
(mode `0700`). Symlinks are copied as links, never followed into outside folders.

The source and backup trees must match SHA-256 digests covering names, file types,
permissions, file contents, and link targets. Verification streams large files in
bounded buffers. Copied files, receipts, and migration checkpoints are flushed to
disk before the migration advances. A backup error, insufficient space, changing
source, or unsupported file prevents the migration from modifying profile data.
Abandoned Codex `CODEX_HOME/ipc/ipc.sock` endpoints are removed only after the
store is confirmed idle and profile locks are held. Active sockets, other
special files, and linked or unsafe IPC directories still stop migration.

**Recovery copies are retained even after successful migration.** No automatic
backup cleanup runs. Failed copies without a verified `receipt.json` remain for
inspection; a later attempt uses a new UUID. On an interrupted migration, the
recorded backup must still verify before any further changes. Backups include
private profile data and must not be uploaded with bug reports. Remove them only
when you have independently confirmed the upgraded profiles work and no longer
need the recovery copy.

- Close other manager instances and all managed provider apps before upgrading.
  Open files or ambiguous process inspection stop migration with a relaunch
  instruction. Official provider apps using their own storage can remain open.
- Root folders and profile directories must be real directories owned by the
  current user. Linked roots, unsafe control files, invalid ownership markers,
  and unmanaged profile paths are rejected.
- A global migration lock, the store lock, and per-profile locks serialize the
  move with other operations. Existing restore/deletion journals recover only
  after the original data is backed up, and before folder relocation.
- A destination `AgentDock` folder containing only the old `ChatIndexes` cache
  and optional Finder `.DS_Store` metadata
  is moved intact to `~/Library/Application Support/AgentDock Legacy Index
  Archives/<UUID>/` before the legacy store is moved. These private archives
  are retained. Other nonempty destination folders are never replaced or
  merged; preserve both and resolve those conflicts before relaunching.
- Directory moves are journaled at
  `~/Library/Application Support/.agentdock-brand-migration-v1.json`. If the app
  exits between a directory move and metadata commit, relaunch completes the
  remaining phases. Do not manually delete this journal during recovery.
- `.brand-migration-v1-complete` is written only after the final store validates.
  Completed migrations do not import an old folder again or reset current data.
- Legacy spellings remain only in compatibility code, upgrade fixtures, and
  this documentation. New profiles use `.agentdock-profile.json`, new operations
  use `.agentdock-locks`, and generated configs use the AgentDock management
  comment. Existing legacy locks remain available for coordination with old
  helper processes; detached legacy profiles are validated when restored.

## Validation

Run `swift test --filter LegacyBrandMigrationTests` for real filesystem and
isolated synthetic Keychain coverage: both providers, interrupted phases,
credential conflicts, encrypted-key preservation, open-file detection, unsafe
roots, profile identity, automatic startup, backup verification/failure/retention,
and one-time preference migration. Shortcut tests cover
same-build refresh after a storage change. Then run `swift test`,
`./script/build_app.sh`, and `./script/package_app.sh`.

Installed-provider launch/login acceptance remains opt in as described in
[Development and testing](development.md); ordinary tests never open provider
applications or migrate the user's real profile directories.
