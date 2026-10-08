# Security Policy

## Supported Versions

| Version | Support |
| --- | --- |
| Latest release | Supported |
| `main` | Best-effort pre-release fixes |
| Older releases | Upgrade before reporting |

Provider compatibility can change when an installed provider app updates.
AgentDock intentionally fails closed when a required signed launch contract can
no longer be verified.

## Report Privately

Do not open a public issue for a vulnerability or include credentials, private
transcripts, account details, absolute local paths, or unredacted logs.

Use GitHub's private vulnerability reporting flow:

[Report a vulnerability privately](https://github.com/euforic/AgentDock/security/advisories/new)

Include:

- affected AgentDock version and macOS version;
- affected provider and provider app version;
- impact and expected security boundary;
- minimal reproduction steps;
- sanitized diagnostics or a proof of concept;
- whether the issue is already public.

Do not include live credentials or another person's data. If sensitive evidence
is necessary, first ask through the private advisory for a safe transfer method.

## Disclosure

Please allow time to validate the report, prepare a fix, and coordinate a
release before public disclosure. Support timelines depend on severity,
reproducibility, provider compatibility, and maintainer availability.

For the documented trust model and shared-host limitations, see
[`docs/security.md`](docs/security.md).
