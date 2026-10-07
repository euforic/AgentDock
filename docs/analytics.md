# Privacy-First Product Analytics

AgentDock product analytics remain off until the user explicitly allows them.
The consent sheet appears only when delivery is configured and the installation
is undecided. Analytics can be disabled immediately in **Settings → Data &
Privacy** without changing any product feature. Explicit choices persist across
upgrades. Installations migrated from the former opt-out policy are returned to
undecided, their old random identifier is deleted, and older app versions remain
fail-closed.

AgentDock uses a small first-party HTTPS client rather than the PostHog Swift
SDK. The official SDK supports macOS, but currently defaults several collection
and remote-config features on and adds a session identifier. The first-party
boundary sends only the schema below and has no autocapture, screen capture,
session replay, feature flags, surveys, push collection, uploaded crash reports,
uploaded logs, or identify calls.

This decision was revalidated on August 28, 2026 against the official
[`posthog-ios` package](https://github.com/PostHog/posthog-ios) (latest stable
tag `3.70.1`), its
[`PostHogConfig`](https://github.com/PostHog/posthog-ios/blob/main/PostHog/PostHogConfig.swift),
and PostHog's [iOS SDK documentation](https://posthog.com/docs/libraries/ios).
The package supports native macOS, but setup defaults include lifecycle/screen
capture, swizzling, push collection, feature-flag preloading, remote config,
and on-disk queuing. Those capabilities and SDK-added session context are a
larger, less auditable boundary than AgentDock needs.

## Collection and Delivery Contract

- A random UUID is created only after consent is granted and is not derived from a device,
  account, profile, provider, filesystem, or hardware identifier.
- The UUID stays stable while analytics is enabled. Opt-out synchronously clears
  pending events and deletes it; later re-enabling creates an unlinkable UUID.
- Events stay in memory for at most five seconds or twelve events. The queue is
  capped at 48 events, never written to disk, and discarded on delivery failure
  or app exit. Only one delivery batch is active at a time, and requests are
  capped at 64 KiB. Successful and failed batch counts
  plus the last bounded failure class are retained in memory; failures also emit
  a local OS log entry containing only that class.
- Every request sets `$geoip_disable: true` and
  `$process_person_profile: false`. Disable IP capture in PostHog too.
- Common context is limited to the random `distinct_id`, schema version, app
  version, macOS major version, and architecture.
- Arbitrary strings cannot enter the API. Names, keys, actions, outcomes,
  providers, features, error codes, and buckets are closed Swift enums.
  Duplicate, missing, excessive, or incompatible properties are rejected.

AgentDock never sends names, email or GitHub identity, provider accounts,
profile names or identifiers, hardware serials, IP-derived location, paths,
commands, prompts, transcript/chat content, local chat or session identifiers,
configuration values, environment variables, logs, crash content, raw errors,
repository/branch/model names, clipboard contents, search text, or timestamps
read from provider data.

Plan and usage telemetry is deliberately coarse. Provider plan strings are
mapped to a closed tier (`free`, `plus`, `pro`, `max`, `team`, `business`,
`enterprise`, `education`, or `unknown`). Usage is reduced to bounded percent
bands and only the highest observed primary and secondary window per profile is
used. Exact percentages, balances, reset times, limit names, and model scopes
never leave the app.

## Event Catalog

| Event | Allowed product properties | Purpose |
| --- | --- | --- |
| `app_lifecycle` | `action`, `trigger`, `countBucket` | First/return launch and coarse activation context. |
| `consent_decision` | `action`, `surface` | User-initiated re-enablement. Denial/revocation is not transmitted. |
| `navigation` | `action`, `surface`, `provider` | Overview, advanced, and settings adoption. |
| `profile_lifecycle` | `action`, `outcome`, `provider`, `countBucket`, `durationBucket` | Create, restore, edit, remove, and delete funnels without identity. |
| `provider_status` | `action`, `outcome`, `provider` | Discovery, configuration, validation, and compatibility. |
| `launcher_lifecycle` | `action`, `outcome`, `provider`, `trigger`, `durationBucket`, `countBucket` | Open/focus/close and shortcut install/repair/remove outcomes. |
| `chat_usage` | `action`, `outcome`, `provider`, `countBucket`, `durationBucket` | Legacy schema retained for older releases; the current app emits no chat-browser events. |
| `refresh` | `action`, `outcome`, `surface`, `trigger`, `countBucket`, `durationBucket` | Manual/automatic refresh reliability and coarse workload. |
| `update_lifecycle` | `action`, `outcome`, `trigger`, `enabled` | Checks and automatic check/download preferences. |
| `preference_changed` | `action`, `surface`, `enabled` | Settings adoption without selected text/values. |
| `error` | `errorCode`, `surface`, `provider`, `action` | Reliability grouped into stable safe codes; no raw errors. |
| `performance` | `durationBucket`, `surface`, `action`, `provider`, `countBucket` | Coarse latency distribution. |
| `feature_adoption` | `action`, `feature`, `surface`, `provider` | Adoption of major capabilities. |
| `profile_inventory` | `action`, `outcome`, `provider`, `profileScope`, `planTier`, `countBucket` | Coarse managed/official profile and plan distribution. |
| `usage_snapshot` | `action`, `outcome`, `provider`, `profileScope`, `planTier`, `usageBucket`, `limitWindow`, `countBucket` | Aggregate quota pressure by safe plan and usage bands. |

Allowed dimensions live in
[`ProductAnalytics.swift`](../Sources/CodexerCore/ProductAnalytics.swift).
Count buckets are `zero`, `one`, `twoToFive`, `sixToTwenty`, and
`twentyOnePlus`. Duration buckets are `under100ms`, `ms100To499`,
`ms500To1999`, `seconds2To9`, and `seconds10Plus`.
Usage buckets are `zero`, `under25`, `percent25To49`, `percent50To74`,
`percent75To89`, `percent90To99`, and `atOrOver100`.

## PostHog Project Setup

Use a dedicated project in the region selected by the privacy owner. Do not
reuse a project containing identified users.

1. Select US (`https://us.i.posthog.com`) or EU
   (`https://eu.i.posthog.com`) ingestion and publish that region.
2. Disable IP capture/GeoIP and person profiles at project level. Do not enable
   replay, autocapture, surveys, feature flags, errors, logs, or raw exports.
3. Restrict access and require SSO/MFA where available.
4. Use the shortest useful retention: 90 days is recommended for raw events
   and no more than 13 months for aggregates. Record the approved periods.
5. Add the public token and regional host as GitHub Actions repository
   variables `POSTHOG_PROJECT_TOKEN` and `POSTHOG_HOST`. Never add a personal or
   project secret API key to the app or build.
6. Build a release, inspect the `AgentDockPostHog*` Info.plist values, and
   launch a synthetic installation. Compare received keys with this catalog.

Without both valid variables, analytics delivery remains disabled.

## Dashboards, Funnels, Cohorts, and Retention

Create a **Product health** dashboard with weekly opted-in active installations;
app-version/update adoption; profile and plan distribution; quota-use bands;
success rates by action/provider; safe error-code trends; latency buckets; and
feature/surface adoption.

Create these funnels:

- activation: app launched → profile created/restored successfully → launcher
  opened successfully within 7 days;
- shortcut: profile created/restored → shortcut installed → shortcut-triggered
  open;
- update: update preference enabled → check → later app version.

Create **activated**, **profile-only**, **shortcut adopter**,
**updates enabled**, and **recent safe error** cohorts only from this catalog.
Use weekly retention with successful activation as the start and
`app_lifecycle` as the return event. Opted-out users are intentionally invisible
and must not be inferred or reidentified. Do not use person profiles, session
views, or identity merges.

## Deletion and Incident Handling

Opt-out deletes the local identifier and queue immediately. Historical events
follow project retention. If a user retained their prior random identifier and
requests early erasure, an authorized operator may delete it in PostHog;
AgentDock never embeds the private credential required. Treat unexpected
properties, person profiles, replay, or exports as a privacy incident: disable
release variables, investigate, delete affected data, and notify as required.
