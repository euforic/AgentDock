# Local activity reader and storage budgets

`ProfileStatsScanner` uses summary-only Claude scans. These retain source-backed
session timestamps, model attribution, token totals, and local usage-limit
signals while skipping presentation titles, previews, repository and branch
details, and change-token construction. Public session and transcript APIs
retain their supported behavior.

The official Claude Code history index reads the newest 16 MiB by default.
It drops an incomplete record at the beginning of that window, visits newest
records first, and observes both record-count and per-record size limits.
Older records remain provider-owned and untouched. Session timestamps and totals
cover only inspected records when those limits apply. Per-session model headers
use a separate 16 MiB scan budget, with at most 256 KiB per session. Header
budgets count bytes actually read, including buffered chunks.

History summaries remain in memory for at most four history/mode combinations.
An unchanged file reuses its summary without reading the history body. Device,
inode, size, and nanosecond modification and change times invalidate cached
summaries after append, replacement, or rewrite. Reads use the existing regular
file, no-follow, and path-containment checks. A file that changes during a read
is marked partial and is not cached. Changed histories reread the bounded recent
window; the reader does not assume that a size increase is an append-only edit.

Claude audit usage summaries retain at most 10,000 entries by default. Least
recently used entries are evicted individually, so adding a source does not
flush every account's summaries. Identity and timestamp checks also invalidate
rewritten or replaced audit sources. Cache hits do not consume the 512 MiB usage
I/O budget. Oversized or unreadable usage records and exhausted inventory or
metadata budgets mark coverage partial, including when a partial summary is
reused. Stats show a partial-coverage message through `errorMessages`.

Storage measurements expire after ten minutes and retain their original
`dataSizeMeasuredAt` timestamp when reused. One- through five-minute refreshes
therefore reuse an explicitly dated measurement. The storage cache retains at
most 64 roots. Entry, depth, time, and cancellation limits preserve lower-bound
semantics through `dataSizeIsTruncated`.

Regression tests use synthetic data in real temporary files. They cover large
histories, unchanged reuse, append/rewrite/replacement invalidation, symlink
rejection, cache eviction across separate accounts, partial coverage, separate
history/header budgets, and dated storage reuse and expiration.
