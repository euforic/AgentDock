# Resource usage finding dispositions

This follow-up verifies the resource audit of `8320d2e` versus `6d2d30f`
against main at `0acab4c`. That main already includes removal of the chat
browser, Desktop-account limits, reset countdowns, and stationary profile tabs.
The changes below retain provider histories and all supported renderer/core APIs.

| Finding | Disposition and evidence |
| --- | --- |
| Recurring background reset work | Fixed: five-minute foreground inventory; thirty-minute inactive inventory; enabled reminders reconcile at queued alert/expiration milestones. Disabled reminders still retain useful inventory. Polling follows its existing deadline rather than restarting the clock on every configuration callback. `ResourceRefreshTests` exercises the cadence decisions; existing reset planner/controller tests cover redemption, expiration, snooze, and queue limits. |
| Duplicate quota and reset-account reads | Fixed: one shared account reader, one-minute maximum result reuse, distinct home/app/credential metadata keys, cancellation per subscriber, four-account serial batches, 256 cached answers. New concurrent real-file failure tests and opt-in signed-in quota tests verify coalescing, cancellation, cache reuse, and app-selection separation. |
| Repeated bundle/contract validation | Fixed: one full validation per new native quota batch and one Claude validation/contract probe per status batch. Signature checks remain. Quota batches capture file identity around validation and recheck it before/after every launch/read; a changed installation fails closed. Modification times do not establish trust. Installed signature/contract tests and batch parity pass. |
| Duplicate process snapshots | Fixed: one snapshot per provider in the combined managed/official batch. Missing/nonexecutable Codex selections return stopped statuses without launching `ps`. Real temporary-file tests cover missing and nonexecutable selections. |
| Activation/multiple-window amplification | Fixed: activation is tracked once per application, recent automatic status reads are throttled for ten seconds, in-flight status reads coalesce, and lifecycle actions request one necessary follow-up. Thirty simultaneous production-service requests complete one batch in the app integration test. |
| Closed-window/focus-loss gate | Reproduced with native SwiftUI/AppKit evidence, then fixed. With all windows closed, the original scene gate remained true while `NSApp.isActive` was true and visible window count was zero; the new app-level monitor was false. A bundled self-contained probe also exercised two windows, one remaining window, hide/return, reopening, and thirty rapid transitions. Its monitor requires both application focus and a visible main-capable window. |
| Proposed older status-result overwrite | No stale overwrite was reproduced against real providers. The verified overlapping-read path was removed; one task owns publication, rejects changed profile/app snapshots, and uses a generation when cancellation starts a replacement. No claim that the audit's hypothetical overwrite was observed. |
| Cancellation and old quota/stats results | Preserved generation/cancellation protections. The shared reader cancels a worker only when all subscribers leave, and a new subscriber arriving behind a cancelled worker queues a new read. Existing generation tests remain; new signed-provider subscriber test uses an isolated temporary home. |
| Stale usage after returning | Fixed: returning catches up activity when its last completed scan exceeds the configured interval, and quota freshness uses successful reads with a one-minute failed-attempt backoff. In-flight work coalesces. Real temporary-file/config integration tests cover fresh, inactive, and stale return cases. |
| Storage-cache reuse | Fixed: ten-minute storage lifetime, at most 64 roots, original measurement timestamp exposed in storage details. Entry/depth/time limits and lower-bound reporting remain. Tests verify one-/five-minute reuse and expiry. |
| 16 MiB history cliff | Fixed: cached bounded recent tail, independent bounded session-header budget, source identity invalidation, and honest partial coverage. A history larger than the limit produces inspected sessions rather than an empty inventory. Real-file tests cover large histories, append/rewrite/replacement, symlinks, line limits, and unchanged reuse. Changed files reread their tail; no append-only assumption. |
| Filesystem discovery in SwiftUI bodies | Fixed: views consume published config snapshots. Discovery runs off the main actor on load/reload, activation, and refresh; cancellation/generation reject obsolete snapshots. Config selection still validates immediately before sensitive actions. |
| Discarded change tokens and session presentation | Fixed in stats scans: skip tokens, titles, previews, branch, and repository work that statistics do not use. Preserve public presentation behavior and model/header attribution. Real-file parity tests cover both paths. |
| Bounded usage-cache wholesale clearing | Reproduced at a small configurable capacity with independent account fixtures; fixed with individual least-recently-used eviction and identity-based invalidation. The cache remains bounded at 10,000 entries. Working sets exceeding capacity can still miss; no claim that every large working set fits. |
| Unchanged published values/persistence | Fixed: permission, config, stats, statuses, schedules, and consolidated inventory avoid equivalent assignments. Reminder snapshots save only when their persisted content changes. A changed freshness timestamp is meaningful and is still saved. |
| Unused app-test renderer dependency | Removed after confirming the app tests do not import the renderer. Renderer library/showcase targets and their tests remain. |
| Packaging/license drift | Fixed: main app packages its root license and Sparkle license; renderer source/library/showcase notices and licenses remain in the repository. Packaging validation requires the actual distributed dependency notices. |
| Dead usage credential code | Removed the unused Code credential reader, its exclusive helpers, and unused official-usage parameter. Live Desktop usage remains separate from Code activity; the official Overview explains that provenance. |
| Legacy public APIs/index cleanup | Verified not dead: supported core session/transcript APIs, index reads/writes, and their performance tests remain consumers. The app does not call the removed browser. Existing managed-index cleanup remains; official metadata indexes are not deleted automatically because supported core callers can still use them. No recurring app scan/index writes were found. |
| SQLite query full-scan hypothesis | No new index or query rewrite: provider databases remain provider-owned. The warning/error aggregate has no repository-controlled schema/index guarantee. The sequential 50,000-session/two-million-log-row fixture completed without query errors or timeouts; no new query regression was demonstrated. Existing aggregate queries stay bounded and read-only. |
| SwiftUI whole-object invalidation/row timelines | No demonstrated defect. Equivalent values now avoid publication; minute-granularity countdown timelines remain useful. No speculative view-architecture rewrite. |
| Missing/replaced providers | Missing/nonexecutable selections skip unnecessary snapshot work. Signature and contract validation fail closed; cached quota answers invalidate on installation/credential metadata changes. Existing unsigned/signature/path/symlink tests remain. |

## Validation and measured evidence

The integrated candidate passed `swift test`: 293 core tests (16 opt-in skips)
and 62 app tests (3 opt-in skips), with zero failures. The separate renderer tests
also passed; vendored parser validation passed 98 tests. Eight opt-in checks
passed against signed installed providers and the real signed-in quota service,
including shared successful cache reuse and subscriber cancellation with an
isolated temporary home. Build, ZIP/DMG packaging, privacy, and site checks passed.
The final local QA reviewed correctness, security, cancellation, bounded memory,
resource lifetime, API compatibility, and packaging; no unresolved actionable
source defect remains from this inventory.

See [sequential measurements](resource-usage-benchmarks.md) for the count-only
receipt and quantitative limits. Source call-count reductions alone are not
CPU, memory, thermal, energy, or deployed-release proof.

## Runtime limits

The resource harness measures production readers and installed signed providers,
not thirty-minute foreground/background app residency. Native lifecycle evidence
comes from a self-contained bundled probe using the exact original scene gate
and the current application monitor. Full UI capture was unavailable: macOS
ScreenCaptureKit failed to start its capture stream. The probe performs native
self-directed transitions and records only window counts/booleans.

Actual system sleep/wake, prolonged real multi-account/window workloads, native
notification presentation/actions and replenishment beyond the queue limit,
and app heat/energy measurements remain runtime acceptance gates. Deliberately
sleeping this working Mac or changing notification permissions was not necessary
for these fixes. Network-byte attribution to short-lived app-server children is
not available in the reader harness; no network reduction is claimed. Native
per-process disk counters may be zero with cached filesystem pages and do not
count every metadata lookup. Provider process workload can change independently;
measurements are sequential and read-only, with no provider lifecycle changes.

The optional system-wide `powermetrics` check reported that superuser access is
required. Process-local wakeup/footprint counters were available without that
permission; system-wide energy attribution was not performed.
