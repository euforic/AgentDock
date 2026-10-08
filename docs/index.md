# AgentDock Documentation

The README is the user-facing entry point. These pages contain the deeper
implementation, contribution, and operations details needed for focused work.

## Project Guides

- [Architecture](architecture.md): runtime components, boundaries, and design
  constraints.
- [Code map](code-map.md): important source, test, workflow, and script
  locations.
- [Data flows](data-flows.md): profile lifecycle, activity summaries, and
  release artifact flows.
- [Interfaces and contracts](apis.md): Swift modules, process contracts,
  environment variables, and persistent formats.
- [Home dashboard](home-dashboard.md): layout, source-backed summaries, navigation,
  and local acceptance boundaries.
- [Banked reset reminders](reset-reminders.md): inventory, native expiration alerts,
  snoozing, freshness, and validation.
- [Resource usage readers](resource-usage-readers.md): bounded histories, partial coverage, and storage freshness.
- [Resource usage QA](resource-usage-qa.md): finding dispositions, validation,
  sequential measurements, and remaining runtime acceptance gates.
- [Development and testing](development.md): local setup, commands, validation,
  and opt-in installed-app checks.
- [Release operations](operations.md): packaging, signing, notarization,
  verification, and publication.
- [Security and privacy](security.md): trust boundaries, local data handling,
  secret handling, and disclosure guidance.
- [Profile isolation and quality audit](audit-2026-09-07.md): findings, fixes,
  validation evidence, and remaining acceptance gates.
- [Privacy policy](privacy.md): local-first and revocable analytics commitments.
- [Product analytics](analytics.md): event catalog, opt-in, PostHog operations,
  dashboards, funnels, cohorts, and retention.

## Community Guides

- [Contributing](../CONTRIBUTING.md)
- [Support](../SUPPORT.md)
- [Security policy](../SECURITY.md)
- [License](../LICENSE)

## Sources of Truth

When documentation and behavior differ, verify and update the documentation
against these repository sources:

- Package and target graph: [`Package.swift`](../Package.swift)
- Continuous integration and releases:
  [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) and
  [`.github/workflows/release.yml`](../.github/workflows/release.yml)
- App packaging: [`script/build_app.sh`](../script/build_app.sh) and
  [`script/package_app.sh`](../script/package_app.sh)
- Profile lifecycle and launch safety:
  [`Sources/CodexerCore`](../Sources/CodexerCore)
- Local activity: [`Sources/CodexerCore/ProfileStats.swift`](../Sources/CodexerCore/ProfileStats.swift)
  and shared [`Sources/CodexerCore/LocalChatSession.swift`](../Sources/CodexerCore/LocalChatSession.swift) readers
- Separate renderer showcase: [`Sources/TranscriptRenderer`](../Sources/TranscriptRenderer)
- Validation: [`Tests`](../Tests)

Documentation should change in the same pull request as any user-visible
behavior, persisted-data contract, security boundary, build command, or release
procedure it describes.
