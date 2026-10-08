# Privacy Policy

AgentDock is local-first. Profile metadata, provider state, and any legacy
chat-browser indexes remain on the Mac except when a provider application
independently uses its own services. AgentDock does not browse chats, copy
transcripts, or create browser indexes. Claude activity summaries still read
supported local session files through bounded core readers and remain in memory.

Pseudonymous product analytics remain off until the user explicitly allows
them. Once allowed, AgentDock sends a random installation identifier and the
bounded [event catalog](analytics.md) to the configured PostHog region. It does
not identify a person or enable automatic capture. Disabling analytics in Data
& Privacy immediately stops collection, clears pending events, and deletes the
identifier. Explicit choices are preserved across updates; installations from
the former opt-out policy are returned to undecided and asked again.

The catalog includes normalized plan tiers, coarse profile-count and quota-use
bands, feature outcomes, and stable issue codes. It excludes exact usage,
balances, reset times, provider limit or model names, raw errors, logs, and
account or profile identity.

Production releases use PostHog's US ingestion region. Raw-event retention
should be limited to 90 days, and aggregate retention must not exceed 13
months. Privacy concerns can be reported through the private security advisory
flow. This policy is effective August 28, 2026. Builds without valid release
configuration cannot deliver analytics.

Signed release builds check the public Stable Sparkle appcast on GitHub Pages
hourly by default so security and reliability updates can be offered promptly.
Users may opt into the separate Alpha appcast in Settings and return to Stable
at any time. Each check is a
standard HTTPS request to GitHub's service and therefore exposes ordinary
network metadata to that service; it does not include profile, account, chat,
or analytics identifiers. Users can change the frequency or disable automatic
checks in **Settings → General** and can still request a manual check.

See [Security and privacy](security.md), [Data flows](data-flows.md), and the
[security policy](../SECURITY.md) for the remaining boundaries.
