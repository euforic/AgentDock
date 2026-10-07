# Banked Reset Reminders

**Available Resets** lists banked Codex resets across the official installation
and managed Codex profiles in a compact, single-line inventory, sorted by
expiration across all accounts by default. A warning strip shows how many
reported available resets expire within seven days and within 24 hours.
**Show expiring soon** filters to the seven-day window. Imminent rows use a
clock, time remaining, and an amber edge; expired or redeemed rows never count
as expiring soon.

Use **Group by → Date, Account, or Profile** and choose soonest expiration,
latest expiration, or recently granted order. Unknown expiration dates stay
at the end of expiration sorts. Search matches account, profile, reset name,
description, and status. Profile groups show a shared reset under each matching
profile; the summary and urgency counts still count the account once.
Account and profile columns remain separate. Descriptions, full dates, and
freshness details are available in tooltips. The row menu retains Open Codex,
Snooze, Stop Reminders, and Resume Now. **Account status** shows confirmed zero,
count-only or partial inventories, unavailable identity, last check times,
and source failures without expanding each reset into a card.

These credits are separate
from automatic five-hour/weekly window resets and pay-as-you-go balances.

AgentDock reads `account/rateLimits/read` using the signed installed app's
bundled CLI and each source's own `CODEX_HOME`. This inventory is independent
of the selected model provider and activity-refresh settings. It does not read
transcripts, redeem resets, or access undocumented backend endpoints.

The response's `rateLimitResetCredits.availableCount` is authoritative. Optional
`credits` rows supply ID, reset type, status, grant time, expiration, title, and
description. A missing summary means unavailable, not zero. A null detail list
means count-only data; detail lists can be capped. The UI reports missing
details and never invents expiration dates. Unknown statuses/types remain
visible but do not trigger expiration alerts. Only available, recognized resets
with a future reported expiration are scheduled.

The reset inventory optionally reads `account/read` with `refreshToken: false`
from the same isolated app-server to obtain the signed-in ChatGPT email for
display. Missing, unsupported, or failed account metadata is labelled as
unavailable (or by a short hashed account label when identity is verified).
Display emails never determine identity or combine accounts; they and profile
aliases are cached locally with the reset inventory and excluded from analytics.
The additional response shares the existing bounded-I/O and timeout limits;
missing display metadata does not discard a successful reset response.

Where the provider supplies `accountId`, profiles sharing that identity are
counted once and receive one reminder per reset. The local cache hashes account
identities and reminder keys; reported reset metadata stays local. Without account identity, profiles remain separate and
are labelled as potentially duplicated. Counts reflect the last successful
provider response; expired detail rows are labelled locally until refresh.

## Configure Alerts

Open **Settings → Notifications** and enable reset expiration notifications.
macOS asks for notification permission. Defaults are:

- Warn seven days, one day, and one hour before expiration.
- Send one reminder at each selected time; additional repetition is off.
- Play a sound, with no quiet hours.
- Snooze notification actions for one hour.

Choose multiple warning times in **Settings → Notifications**. Presets include
seven days, three days, one day, six hours, one hour, and fifteen minutes.
Custom warnings accept minutes, hours, or days. An optional repeat interval
adds reminders between the earliest selected warning and expiration; zero
uses only the selected warning times. Settings apply equally to every account
and reset, with no per-account or per-reset configuration overrides.
Quiet hours use the current local timezone; reminders move before quiet hours
when postponing would pass expiration.

**Notification Settings** opens the native settings pane. Choose **Alerts**
there for persistent alerts; macOS controls banner style, sound, previews, and
Focus suppression. **Send Test Notification** verifies native presentation
without creating a reset or using account data.

## Snooze and Act

Notifications offer **View Reset**, **Snooze**, and **Stop Reminders**.
View Reset opens the corresponding row and refreshes its account inventory.
**Open Codex** opens/focuses a matching managed profile or the official app,
where the user can redeem the reset through the provider UI.

Snooze uses the configured duration. The row also offers one hour, four hours,
tomorrow, or a custom time. Snoozes must end before expiration. **Resume Now**
clears snooze/stop state. Dismissing a banner leaves later reminders enabled.
Snooze and stop state persist across restarts.

## Delivery and Freshness

Notifications are finite, one-shot `UNUserNotificationCenter` requests with
stable IDs. They are cancelled/replaced when settings, account inventory, or
expiration dates change. Redeemed/expired resets and removed accounts no longer
have pending alerts after reconciliation. Newly discovered overdue reminders
produce one catch-up rather than one alert for every missed milestone.

Monitoring refreshes every five minutes while AgentDock has an active visible
window, and every thirty minutes while inactive or without windows. Enabled
reminders bring reconciliation forward to the next queued alert or expiration
(with a one-minute minimum); this replenishes the finite native queue. Inventory
still refreshes when reminders are disabled. Launch, source changes, and manual
refresh request new data; activation and wake reuse recent successful reads and
back off failed attempts for a minute. Display and reset inventory share each
account's bounded native quota read, with a maximum one-minute result cache.
Each new batch validates the installed bundle once before using its executable;
metadata invalidates cached answers and never establishes bundle trust. Failed reads retain the
last successful inventory with a stale warning. Count-only responses retain
previously known expiration details for the same account, labelled stale; a
confirmed zero clears them. Scheduled notifications can
appear while AgentDock is closed, using its last checked availability; changes
made elsewhere cannot be detected until it runs again. Focus, sleep, shutdown,
and system notification preferences can delay or suppress presentation.

The nearest 60 upcoming alerts are scheduled to keep native queue usage bounded.
A visible warning indicates when later alerts require a refresh. Keep
AgentDock running for ongoing inventory and schedule updates.

Global preferences, snoozes, scheduling state, and last-known
reset metadata are stored locally in a bounded UserDefaults snapshot. No
credentials, home paths, or reset/account metadata are sent to analytics.

## Validation

Run `swift test`. Reset tests exercise parsing real-shaped synthetic JSON,
provider counts/partial details, account deduplication, finite schedules,
quiet hours, snoozing, unsupported states, and real isolated preferences.
They do not use mocked provider services.

For synthetic view inspection:

```bash
AGENTDOCK_RESET_VISUAL_AUDIT_DIR=/tmp/agentdock-reset-visuals swift test \
  --filter ResetReminderControllerTests/testSyntheticResetViews
```

In the packaged application, enable native alerts, send a test notification,
and verify banner/alert presentation. Check a real available reset's next
reminder, native View/Snooze/Stop actions, custom snooze rejection at expiry,
restart persistence, and delivery after quitting. These manual checks require
macOS notification permission and a signed-in account with eligible resets;
passing unit tests or building a package alone does not establish them.

To verify display metadata through the real signed-in installed Codex CLI:

```bash
AGENTDOCK_LIVE_RESET_ACCOUNT_DISPLAY=1 swift test \
  --filter CodexAccountDisplayParserTests/testInstalledCodexAccountDisplayRoundTrip
```

This read uses the official Codex home, requests no proactive token refresh,
and never prints account metadata. Normal tests skip it.
