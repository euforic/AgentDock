# Home dashboard

Home is the primary sidebar destination and the default startup choice. Existing
persisted Last Opened Profile and Overview preferences remain supported. A legacy
Chats startup preference migrates to Overview, preserving other preferences.
Command-1 returns to Home. Profile and official-app overviews remain accessible
through the sidebar, the source name, or the row's context menu.

Home is a status dashboard. A summary strip shows how many accounts are running,
the banked-reset count and next expiration, the account closest to a usage
limit, and the next usage-window reset. Each tile opens the matching place.

Below it, a native table lists every official installation and managed profile,
grouped by provider. Columns show the account (with running state and plan),
the session and weekly usage windows as inline meters with a reset countdown,
banked resets for Codex accounts, and an Open or Focus action. Selecting a
column header sorts within each provider; double-clicking a row opens its
details, and the context menu offers Open or Focus and Show Details. Those
actions reuse the existing validated launch and focus paths. Missing process
status is shown as unavailable rather than stopped. A profile metadata reload
leaves Home selected. AgentDock has no chat-browser destination or
transcript-copying action.

## Data and reset counts

Usage comes directly from the model's existing `ProfileRateLimits` snapshots.
The Session column shows the shortest reported window (under a day) and the
Weekly column the longest; other windows remain available in Overview. No
account quotas are added together. Meters turn orange at 75 percent and red at
90 percent. Failed reads mark the account "Usage unavailable" with the reason
in help, and unreported windows show a dash. Countdowns update locally once per
minute without additional provider reads; elapsed reset times show "Reset due".
These times describe usage allowances, not banked-reset expiration.

Banked resets come from `ResetReminderController.accounts`. The summary uses
its verified account grouping and the provider's reported count, and each Codex
row shows the count associated with its source ID. Aliases of one verified
account show the same allowance; they do not create extra resets. An unknown
inventory (a dash) is distinct from a confirmed zero. Claude rows do not show
Codex banked resets. A known available reset expiring within seven days shows
an amber expiration time, red within 24 hours; expired and used credits do not.
Selecting a count opens Available Resets with the expiring reset selected.
Home adds no polling, notification scheduling, reset consumption, or account
persistence.

## Design

Home uses standard macOS components: a `Table` with provider sections and
sortable columns, linear capacity gauges, semantic text styles, and system
colors. Long account names truncate with the full name in help and
accessibility labels. Both appearances use the same layout.

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
