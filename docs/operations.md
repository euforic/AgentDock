# Release Operations

## Local Packaging

Build and package an ad-hoc signed app:

```bash
./script/build_app.sh
./script/package_app.sh
```

Outputs:

```text
dist/AgentDock-<version>.zip
dist/AgentDock-<version>.dmg
```

The build script embeds the pinned Sparkle framework with its updater and XPC
services, signs every nested component before the outer app, and verifies the
result. The package script verifies the app structure, rejects filesystem
metadata sidecars, mounts the DMG read-only, scans it for build-machine paths,
and runs DMG integrity verification. The ZIP contains `AgentDock.app` at its
root, as required by Sparkle's archive extractor. An ad-hoc local build has no
Sparkle public key and keeps update checks disabled.

It also has no PostHog configuration, so product analytics cannot leave the
process. Production analytics require the two repository variables described
in [Product analytics](analytics.md). Configure them only after reviewing the
project region, IP capture, person profiles, access, and retention. The build
accepts only a public `phc_` token and an official US or EU ingestion host.

## Continuous Integration and Release Channels

`.github/workflows/ci.yml` validates pull requests and every push to `main`. It
runs the root and vendored test suites, the repository privacy audit, and an
ad-hoc build/package cycle. `.github/workflows/release.yml` remains tag-only and
accepts stable `v*` tags plus automated `alpha-*` tags. Its dispatch entrypoint
is reserved for the Alpha trigger and rejects stable tags; it has no branch,
pull-request, schedule, or general manual-release path. Equivalent
local validation is:

```bash
swift test
swift test --package-path Vendor/streamdown-swift
./script/audit_privacy.sh
./script/build_app.sh
./script/package_app.sh
```

The tag workflow:

1. serializes all releases, validates stable `vMAJOR.MINOR.PATCH` tags or
   automated Alpha tags, and requires their commit to be on `origin/main`;
2. rejects stable version rollback against tags and the public appcast, then
   runs both test suites (Alpha tags reuse the successful `Quality` run for the
   exact commit);
3. builds with an offset workflow run number as a monotonic numeric
   `CFBundleVersion`, so a later Stable build can supersede an earlier Alpha;
4. signs Sparkle's nested components and AgentDock with Developer ID and the
   hardened runtime;
5. notarizes, staples, and verifies the app and DMG with Gatekeeper;
6. publishes the ZIP, DMG, and checksums to the immutable GitHub Release;
7. downloads the public ZIP and byte-compares it with the notarized workflow
   artifact before generating an Ed25519-signed appcast;
8. pushes the signed feeds to `gh-pages` only after every earlier gate succeeds;
9. polls each published Pages URL until its bytes exactly match the generated
   feed, then verifies its Ed25519 signature again.

Stable clients use `https://gh.euforic.one/AgentDock/appcast.xml`. Alpha
clients use `https://gh.euforic.one/AgentDock/appcast-alpha.xml`, which
also retains Stable entries as a fallback. Every Stable release refreshes both
feeds, preserving the latest Alpha entry in the Alpha feed. Alpha subscribers
receive a Stable build when its numeric build number is newer than their
installed build, without changing their selected channel. Older Stable builds
do not replace newer Alpha builds. Stable is the app default and users
can change channels at any time in Settings. Configure
GitHub Pages to publish from the root of the `gh-pages` branch before the first
Sparkle-enabled release.

`.github/workflows/alpha-trigger.yml` waits for a successful `Quality` run on a
push to `main`, then waits ten minutes before tagging that exact revision. Its
cancel-in-progress concurrency group coalesces nearby merges: a newer merge
cancels the older wait, and only the newest tested `main` revision advances to
the expensive signed and notarized pipeline. The trigger dispatches that
pipeline explicitly because GitHub suppresses recursive tag workflow runs from
the default Actions token. Alpha GitHub Releases are marked
as prereleases and never replace the latest Stable release.

AgentDock is maintained in the personal `euforic/AgentDock` repository. CI and
release jobs use GitHub-hosted `macos-26` (Apple silicon) and `ubuntu-24.04`
runners, so they do not depend on organization runner access. Standard runner
minutes are free while this repository is public. Temporary workflow artifacts
expire after one day; GitHub Release assets remain available for downloads. Repository
**Settings → Actions → General** must allow Actions; publication jobs explicitly
request `contents: write`. Keep the `release` environment, its signing secret,
and its `v*` / `alpha-*` tag deployment policies configured.

The ownership migration changes the website and both update feeds to
`https://gh.euforic.one/AgentDock/`. GitHub redirects the old repository and
release URLs automatically, but does not redirect the old Pages site. Install
a release built after the migration manually once if your installed app still
uses the old feed. The bundle identifier, profile storage, and signing keys
remain unchanged. Previously signed appcasts and immutable release archives
retain their original URLs until superseded by a new signed release; do not
edit a signed feed without re-signing it.

The release action intentionally omits `target_commitish`: the `v*` tag already
identifies the exact release commit. Supplying a target commit that changes a
workflow relative to the current default branch makes GitHub require workflow
write access, which the built-in `GITHUB_TOKEN` cannot receive. When diagnosing
a release API 403, confirm that the tag points at the intended commit and do not
work around this boundary with a broad personal access token.

## One-Time Sparkle Key Setup

The repository does not contain a release key. A release operator must create
one long-lived key once using the `generate_keys` binary from the pinned
Sparkle 2.9.6 distribution. Use a distinct Keychain account for AgentDock:

```bash
sparkle_bin='.build/artifacts/sparkle/Sparkle/bin'
"$sparkle_bin/generate_keys" --account dev.euforic.agentdock
private_key_file="$(mktemp -t agentdock-sparkle-key)"
"$sparkle_bin/generate_keys" --account dev.euforic.agentdock -x "$private_key_file"
gh secret set SPARKLE_PRIVATE_ED_KEY \
  --repo euforic/AgentDock \
  --env release \
  < "$private_key_file"
gh variable set SPARKLE_PUBLIC_ED_KEY \
  --repo euforic/AgentDock \
  --body "$("$sparkle_bin/generate_keys" --account dev.euforic.agentdock -p)"
rm -P "$private_key_file"
```

Create and protect the `release` GitHub environment before these commands.
Require an appropriate reviewer and restrict deployment branches/tags according
to the repository's release policy. Back up the private key in an approved
secret store; losing it prevents existing clients from trusting future updates.
Never rotate or replace it casually.

The protected `release` environment also gates the Developer ID, notarization,
and appcast signing jobs. Store all of these secrets in that environment:

- `DEVELOPER_ID_CERTIFICATE_PEM_BASE64`
- `DEVELOPER_ID_PRIVATE_KEY_PEM_BASE64`
- `APPLE_NOTARY_KEY_P8_BASE64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

## Publish a Release

After the key, environment, and Pages source are configured, create an immutable
version tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

There is intentionally no manual Actions release button. Do not move a
published tag after users have downloaded its assets. Issue a new patch version
for corrections.

Pre-Sparkle installations cannot discover the appcast. Users of those builds
must install the first Sparkle-enabled release manually from GitHub one final
time; subsequent releases update automatically according to their settings.

## Verify a Download

Download all three release files into the same directory, then run:

```bash
sed 's#  dist/#  #' AgentDock-<version>.sha256 | shasum -a 256 -c -
xcrun stapler validate AgentDock-<version>.dmg
spctl --assess --type open --context context:primary-signature \
  --verbose=4 AgentDock-<version>.dmg
hdiutil verify AgentDock-<version>.dmg
curl --fail --silent --show-error \
  https://gh.euforic.one/AgentDock/appcast.xml \
  | xmllint --noout -
```

## Rollback

GitHub Releases are immutable historical records once downloaded. If a release
is defective, document the issue, fix `main`, and publish a new patch release.
Do not silently replace trusted artifacts or move a published tag. Because the
appcast is published last, a failed build, notarization, release upload, or
appcast-signing job leaves clients on the previous valid feed.
