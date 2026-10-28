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
