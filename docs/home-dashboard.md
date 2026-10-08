# Home dashboard

Home is the primary sidebar destination and the default startup choice. Existing
persisted Last Opened Profile and Overview preferences remain supported. A legacy
Chats startup preference migrates to Overview, preserving other preferences.
Command-1 returns to Home. Profile and official-app overviews remain accessible
through the sidebar, the source name, or the row's chevron.

Home groups the official installation and managed profiles under their provider.
Each row shows the source identity, observed running state, reported usage, and
an Open or Focus action. Those actions reuse the existing validated launch and
focus paths. Missing process status is shown as unavailable rather than stopped.
A profile metadata reload leaves Home selected. AgentDock has no chat-browser
destination or transcript-copying action.

## Data and reset counts

Usage comes directly from the model's existing `ProfileRateLimits` snapshots.
Home shows the first two reported windows with their actual duration and bucket
name; additional windows remain available in Overview. No account quotas are
added together. Missing snapshots and failed reads show explicit unavailable
states. Each meter shows its reported usage reset date/time and time remaining,
updated locally once per minute without additional provider reads. Unknown reset
times stay explicit; elapsed dates show a reset-due prompt to refresh usage. These
dates describe usage allowances, not banked-reset expiration. No checked-time
timestamp is shown; snapshots older than ten minutes show a last-known qualifier,
and provider warnings remain visible.

Banked resets come from `ResetReminderController.accounts`. The top panel uses
its verified account grouping and the provider's reported count. Each Codex row
shows the count associated with its source ID. Aliases of one verified account
show the same allowance; they do not create extra resets. An unknown inventory
is distinct from a confirmed zero. Claude rows do not show Codex banked resets.

The compact banner uses a title and one detail line, with a separate qualifier
only for incomplete or stale inventory. The amber row icon marks a known available
reset expiring within seven days. The banner and row icon turn red when a known
available reset expires within the next 24 hours; the banner also states that
urgency in text.
Expired and used credits do not trigger the icon. Missing expiration details,
unverified identities, old inventory, and source errors remain explicit. The
count opens Available Resets through `showsAvailableResets`; if an expiring reset
exists, its key is selected for the existing reset view. Home adds no polling,
notification scheduling, reset consumption, or account persistence.

## Design reference

[Native light reference](design/home-reference-light.png) was generated with the
built-in image generation tool. The reference uses a native sidebar and toolbar,
a single compact reset panel, and flat provider groups separated by hairlines.
There is no large page heading or aggregate metric strip. The implementation
uses system typography, 22-point content gutters, 14-point row padding, 8-point
corners, semantic macOS surfaces, and blue/orange usage accents. Long source names
truncate with full names available in help and accessibility labels. Both native
appearances use the same layout.

The image's example values are synthetic. Generated decorative bars and action
labels do not override actual source availability or lifecycle state.

Generation brief: native macOS AgentDock Home, light appearance, compact sidebar
and toolbar; banked reset panel followed by Codex and Claude source rows; per-Codex
available reset counts and expiration icons (amber within seven days, red within
24 hours); source usage meters; native
Open/Focus and Overview actions; no large heading, summary metrics, or checked
timestamps; flat surfaces, SF typography, 22-point gutters, 8-point corners, and
synthetic data only.

## Validation

```bash
swift test --filter 'HomeDashboardTests|ProfileSelectionIsolationTests|AgentDockPreferencesTests'
AGENTDOCK_VISUAL_AUDIT_DIR=/tmp/agentdock-home-audit swift test \
  --filter ProfileSelectionIsolationTests/testSyntheticVisualAudit
swift test
```

The native visual audit renders Home and Overview in light/dark appearances
at 1080×720 and 900×600 with real temporary profile records, production services,
and an isolated synthetic reset inventory. Review the images for readable rows,
long-name truncation, contrast, and navigation identity. Rendering does not prove
signed-in provider retrieval, installed-app Open/Focus behavior, notification
acceptance, packaging, or release acceptance. Those are separate opt-in checks in
[Development and testing](development.md).
