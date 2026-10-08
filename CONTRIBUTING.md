# Contributing to AgentDock

Thank you for helping improve AgentDock. Focused bug fixes, tests,
documentation, accessibility improvements, performance work, and well-scoped
feature proposals are welcome.

## Before You Start

- Search existing issues before opening a new one.
- Use a feature request for behavior changes that affect persistence, provider
  contracts, security boundaries, or the user workflow.
- Keep unrelated changes out of the same pull request.
- Never include credentials, account data, real transcripts, absolute local
  paths, or unredacted logs.

AgentDock uses the
[Functional Source License 1.1 with an MIT future grant](LICENSE). Review its
current permitted-purpose and competing-use restrictions before contributing.

## Development

Requirements and commands are documented in
[`docs/development.md`](docs/development.md). The standard validation command is:

```bash
swift test
```

Run the relevant installed-app checks only when your change depends on a signed
local provider build. Never replace repository-native validation with mocks or
stubs.

## Pull Requests

A good pull request:

- explains the user-visible problem and the chosen behavior;
- stays small enough to review;
- includes tests for changed behavior and failure cases;
- preserves profile, process, path, and signature safety boundaries;
- updates user or contributor documentation when contracts change;
- reports exact validation performed and any checks that were intentionally
  skipped;
- contains no generated build products or personal/session data.

Write commit messages and pull-request titles that describe the project change,
not the tools or process used to create it.

## Review Expectations

Maintainers may request changes for correctness, scope, accessibility,
performance, privacy, security, compatibility, or documentation. A green build
does not replace review of provider contracts or destructive profile behavior.

Participation is also subject to the
[GitHub Community Guidelines](https://docs.github.com/en/site-policy/github-terms/github-community-guidelines).
A project-specific code of conduct will be added when a private maintainer
reporting channel is available.
