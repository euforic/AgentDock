# Quality, Isolation, and Release Safety Review

Date: August 30, 2026

## Executive Summary

AgentDock now enforces a stronger and more truthful boundary around the work it
can control: profile-owned files, supported provider state, process identity,
bounded local reads, optional analytics, and signed release publication. It is
still intentionally not an operating-system sandbox. Provider applications run
as the signed-in macOS user and therefore retain that user's normal files,
Keychain, shell, network, Git, SSH, permissions, and updater state.

The review combined three independent source passes, adversarial tests, root and
vendored test suites, package/build inspection, privacy scans, and primary-source
research. No credential material, provider data, real transcript content, or
user-specific path was introduced into the repository.

## Confirmed Findings and Resolutions

| Priority | Finding | Resolution |
| --- | --- | --- |
| High | Custom-provider usage parsing could overflow or trap on adversarial numeric values and represented provider activity as an unrelated quota shape. | The `/usage` meter contract now caps meter counts, text, windows, and amounts; rejects non-finite or unsafe values; avoids narrowing numeric conversions; and has overflow regressions. |
| High | SQLite validation could be raced through database or WAL/SHM symlinks. | Database and sidecar files are `lstat`-validated as regular files, canonical parent paths are used, and every CLI open uses `-nofollow -readonly`. Immutable mode is used only without live sidecars. |
| High | Several persisted control-file reads trusted a prior metadata check, followed symlinks, or had no hard byte limit. | A shared descriptor-based reader now uses `O_NOFOLLOW`, rejects non-regular files and FIFOs, and enforces per-format byte limits for profile metadata, journals, ownership markers, provider state, MCP/shortcut configuration, indexes, icons, and bundle property lists. |
| High | Codex source enumeration and profile-size traversal could consume unbounded work; byte accumulation could overflow. | Inventories, entry counts, depth, elapsed time, and byte totals are bounded. Partial storage totals are explicitly shown as “At least …” and cancelled partial scans are not cached. |
| High | Claude OAuth usage used an unbounded whole-response load. | Response delivery is streamed with a 1 MiB limit and bounded request/resource timeouts. Provider credential and state files use the bounded reader. |
| High | Claude close retained a PID-only AppKit termination fallback after identity-aware capture. A recycled PID could target an unrelated process. | The PID-only termination loop was removed. Close escalation remains bound to validated captured process identities. |
| High | Analytics were automatically granted while the UI said nothing was sent until the user chose Allow. | Analytics are now explicit opt-in. Former v1 default grants migrate to undecided, old identifiers are deleted, legacy builds remain denied after downgrade, and the prompt appears only in configured builds. |
| High | Release secrets were consumed before an environment gate; parallel tags, rollback tags, workflow-local asset checks, and an unverified Pages cache could weaken publication. | Stable releases are globally serialized, environment-gated, constrained to `origin/main` and monotonic versions, run root and vendored suites, byte-compare the public ZIP, publish the appcast last, poll for exact public feed bytes, and reverify its signature. |
| Medium | Pull requests and `main` had no repository CI gate. | The Quality workflow now runs root and vendored tests, the privacy audit, and a full ad-hoc build/package cycle. |
| Medium | Every application launch/termination notification caused a full provider status refresh. | Notifications are filtered to supported provider bundle identifiers and coalesced. |
| Medium | Claude history selection repeatedly scanned for the oldest record. | Bounded records are collected once, sorted once, and truncated once. |
| Medium | Creation/deletion copy implied that credentials were profile-contained and deleted. | UI and documentation now distinguish managed provider state from shared macOS Keychain and external credential stores. |
| Medium | Two app animations ignored Reduce Motion. | Nonessential profile-sheet and update-button animations now honor the system accessibility preference. |

## Isolation Decision

Apple's [App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
is the correct default for ordinary standalone apps, but it is incompatible with
AgentDock's core responsibility to inspect, launch, focus, and terminate
separately installed peer applications. Enabling it would either break the
product or invite broad entitlements that obscure the boundary.

Apple's newer [local app data container protection](https://developer.apple.com/documentation/xcode/protecting-local-app-data-using-containers)
is worth future compatibility testing for AgentDock-owned metadata. It would
not isolate provider processes or the user's shared Keychain, filesystem,
network, shell, Git, or SSH resources. Separate macOS accounts or a stronger
virtualization boundary remain the recommendation when those resources must not
be shared.

## Dependency and Update Review

Sparkle remains pinned exactly to 2.9.6. The reviewed recent Sparkle advisories
([one](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5),
[two](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp),
[three](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gmj2-gq3j-vqmj))
are patched in that line. AgentDock retains Sparkle's complementary HTTPS,
Developer ID, notarization, EdDSA, signed-feed, and verify-before-extraction
checks described in the [Sparkle documentation](https://sparkle-project.org/documentation/)
and [publishing guidance](https://sparkle-project.org/documentation/publishing/).

The transitive Highlightr dependency is lightly maintained. It is not currently
a release blocker because rendered provider content does not execute HTML,
scripts, images, or Mermaid code, and the dependency is pinned through package
resolution. Replacing it should be evaluated separately with visual and
performance acceptance tests rather than folded into a security patch.

## Privacy and Accessibility

The existing allowlisted analytics client is intentionally narrower than the
official SDK configuration surface visible in
[`PostHogConfig`](https://github.com/PostHog/posthog-ios/blob/main/PostHog/PostHogConfig.swift).
Consent now precedes identifier creation or delivery, which is also the
conservative interpretation of privacy by default in the
[GDPR](https://eur-lex.europa.eu/legal-content/EN/TXT/PDF/?qid=1787363361336&uri=CELEX%3A02016R0679-20160504).
Analytics remain bounded, memory-only, person-profile-disabled, and GeoIP-disabled.

Motion changes follow Apple's
[`accessibilityReduceMotion`](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)
environment contract. The transcript renderer already honored it; the remaining
app-level transitions now do too.

## Residual Limits and Follow-up

- The five Developer ID and notarization secrets predate this review and are
  repository-scoped in GitHub. Jobs are now protected by the `release`
  environment, but moving those existing secrets into the environment requires
  an owner to re-enter their values; GitHub does not expose secret values for
  migration.
- Installed-provider lifecycle tests remain opt-in because they can open or
  terminate local applications. Synthetic and identity-contract coverage runs
  in CI; live provider acceptance is a separate manual gate.
- A genuine N-to-N+1 Sparkle installation can only be accepted after the new
  release is public. The workflow proves signed/notarized artifact publication,
  public enclosure equality, and public feed signature separately.
- Application-state separation cannot prevent a provider, plugin, shell command,
  or user-approved tool from accessing resources available to the macOS account.

## Validation Record

The change includes focused adversarial coverage for symlinks, FIFOs, oversized
files and responses, inventory limits, numeric overflow, consent migration,
workspace notification filtering, storage lower bounds, SQLite sidecars, and
release workflow invariants. Local validation completed with 248 root-package
tests passing (seven opt-in installed-provider tests skipped), all 106 vendored
renderer tests passing, the privacy audit passing, clean gitleaks and Semgrep
security scans, clean shell/YAML/workflow validation, and successful ad-hoc app
build and package verification. GitHub CI, merge, signed release, and public-feed
results are recorded separately in the pull request and release run so local,
merge, publication, and deployed-update evidence remain distinct.
