#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${AGENTDOCK_APP_NAME:-AgentDock}"
BUNDLE_ID="${AGENTDOCK_BUNDLE_ID:-dev.euforic.agentdock}"
PRODUCT_BINARY_NAME="AgentDock"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${AGENTDOCK_DIST_DIR:-$ROOT_DIR/dist}"
BUILD_SCRATCH_DIR="${AGENTDOCK_BUILD_SCRATCH_DIR:-$ROOT_DIR/.build}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_LICENSES="$APP_RESOURCES/Licenses"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

VERSION="${AGENTDOCK_VERSION:-${CODEXER_VERSION:-}}"
if [[ -z "$VERSION" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
  VERSION="${GITHUB_REF_NAME#v}"
fi
VERSION="${VERSION:-0.1.1}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then
  echo "error: AGENTDOCK_VERSION must use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-alpha.NUMBER format" >&2
  exit 1
fi
BASE_VERSION="${VERSION%%-*}"
IFS=. read -r VERSION_MAJOR VERSION_MINOR VERSION_PATCH <<<"$BASE_VERSION"
if (( 10#$VERSION_MAJOR > 999 || 10#$VERSION_MINOR > 999 || 10#$VERSION_PATCH > 999 )); then
  echo "error: release version components must be no greater than 999" >&2
  exit 1
fi
DERIVED_BUILD_NUMBER="$((10#$VERSION_MAJOR * 1000000 + 10#$VERSION_MINOR * 1000 + 10#$VERSION_PATCH))"
BUILD_NUMBER="${AGENTDOCK_BUILD_NUMBER:-${CODEXER_BUILD_NUMBER:-$DERIVED_BUILD_NUMBER}}"
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: AGENTDOCK_BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi
SPARKLE_PUBLIC_KEY="${AGENTDOCK_SPARKLE_PUBLIC_KEY:-}"
POSTHOG_PROJECT_TOKEN="${AGENTDOCK_POSTHOG_PROJECT_TOKEN:-}"
POSTHOG_HOST="${AGENTDOCK_POSTHOG_HOST:-}"
if [[ -n "$POSTHOG_PROJECT_TOKEN" || -n "$POSTHOG_HOST" ]]; then
  if [[ ! "$POSTHOG_PROJECT_TOKEN" =~ ^phc_[A-Za-z0-9_-]{8,128}$ ]]; then
    echo "error: AGENTDOCK_POSTHOG_PROJECT_TOKEN must be a public phc_ project token" >&2
    exit 1
  fi
  if [[ "$POSTHOG_HOST" != "https://us.i.posthog.com" && "$POSTHOG_HOST" != "https://eu.i.posthog.com" ]]; then
    echo "error: AGENTDOCK_POSTHOG_HOST must select the configured US or EU ingestion region" >&2
    exit 1
  fi
fi
if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
  SPARKLE_KEY_CHECK="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/agentdock-sparkle-key.XXXXXX")"
  trap '/bin/rm -f "$SPARKLE_KEY_CHECK"' EXIT
  if ! printf '%s' "$SPARKLE_PUBLIC_KEY" | /usr/bin/base64 -D >"$SPARKLE_KEY_CHECK" 2>/dev/null \
    || [[ "$(/usr/bin/wc -c <"$SPARKLE_KEY_CHECK" | /usr/bin/tr -d ' ')" != "32" ]]; then
    echo "error: AGENTDOCK_SPARKLE_PUBLIC_KEY must be a base64-encoded 32-byte Ed25519 public key" >&2
    exit 1
  fi
  /bin/rm -f "$SPARKLE_KEY_CHECK"
  trap - EXIT
fi
SIGNING_IDENTITY="${AGENTDOCK_SIGNING_IDENTITY:-${CODEXER_SIGNING_IDENTITY:--}}"
SIGNING_KEYCHAIN="${AGENTDOCK_SIGNING_KEYCHAIN:-${CODEXER_SIGNING_KEYCHAIN:-}}"

BUILD_ARGUMENTS=(
  -c release
  --jobs "${AGENTDOCK_BUILD_JOBS:-2}"
  --scratch-path "$BUILD_SCRATCH_DIR"
  -debug-info-format none
)
append_prefix_map() {
  local source_path="${1%/}"
  local replacement_path="$2"
  local prefix_map="$source_path=$replacement_path"
  BUILD_ARGUMENTS+=(
    -Xswiftc -debug-prefix-map
    -Xswiftc "$prefix_map"
    -Xswiftc -file-prefix-map
    -Xswiftc "$prefix_map"
    -Xcc "-fdebug-prefix-map=$prefix_map"
    -Xcc "-ffile-prefix-map=$prefix_map"
  )
}

append_prefix_map "$ROOT_DIR" "/workspace/AgentDock"
if [[ -n "${RUNNER_TEMP:-}" ]]; then
  append_prefix_map "$(dirname "$RUNNER_TEMP")" "/workspace"
fi
if [[ -n "${TMPDIR:-}" ]]; then
  append_prefix_map "$TMPDIR" "/workspace/tmp"
fi

swift build "${BUILD_ARGUMENTS[@]}" --product "$PRODUCT_BINARY_NAME"
swift build "${BUILD_ARGUMENTS[@]}" --product AgentDockShortcutLauncher
BUILD_DIR="$(swift build "${BUILD_ARGUMENTS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$PRODUCT_BINARY_NAME"
HELPER_BINARY="$BUILD_DIR/AgentDockShortcutLauncher"
SPARKLE_DISTRIBUTION="$BUILD_SCRATCH_DIR/artifacts/sparkle/Sparkle"
SPARKLE_SOURCE="$SPARKLE_DISTRIBUTION/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_FRAMEWORK="$APP_FRAMEWORKS/Sparkle.framework"

if [[ ! -d "$SPARKLE_SOURCE" ]]; then
  echo "error: Sparkle.framework was not resolved at $SPARKLE_SOURCE" >&2
  exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS" "$APP_LICENSES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$HELPER_BINARY" "$APP_RESOURCES/AgentDockShortcutLauncher"
/usr/bin/ditto "$SPARKLE_SOURCE" "$SPARKLE_FRAMEWORK"
cp "$ROOT_DIR/LICENSE" "$APP_RESOURCES/LICENSE.txt"
cp "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
cp "$SPARKLE_DISTRIBUTION/LICENSE" "$APP_LICENSES/Sparkle-MIT.txt"
chmod 0644 "$APP_RESOURCES/LICENSE.txt" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md" "$APP_LICENSES"/*.txt
if [[ -f "$ROOT_DIR/Assets/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Assets/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi
chmod +x "$APP_BINARY"
chmod +x "$APP_RESOURCES/AgentDockShortcutLauncher"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>SUFeedURL</key>
  <string>https://gh.euforic.one/AgentDock/appcast.xml</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <real>3600</real>
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>AgentDockPostHogProjectToken</key>
  <string>$POSTHOG_PROJECT_TOKEN</string>
  <key>AgentDockPostHogHost</key>
  <string>$POSTHOG_HOST</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.developer-tools</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_component() {
  local preserve_entitlements="$1"
  local target="$2"
  SIGNING_ARGUMENTS=(
    --force
    --sign "$SIGNING_IDENTITY"
  )
  if [[ "$SIGNING_IDENTITY" != "-" ]]; then
    # Hardened runtime library validation requires a real signing team.
    # Ad-hoc development bundles cannot satisfy it for embedded frameworks.
    SIGNING_ARGUMENTS+=(--options runtime --timestamp)
  fi
  if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    SIGNING_ARGUMENTS+=(--keychain "$SIGNING_KEYCHAIN")
  fi
  if [[ "$preserve_entitlements" == "yes" ]]; then
    SIGNING_ARGUMENTS+=(--preserve-metadata=entitlements)
  fi
  /usr/bin/codesign "${SIGNING_ARGUMENTS[@]}" "$target"
}

SPARKLE_VERSION_DIR="$SPARKLE_FRAMEWORK/Versions/B"
sign_component no "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
sign_component yes "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
sign_component no "$SPARKLE_VERSION_DIR/Autoupdate"
sign_component no "$SPARKLE_VERSION_DIR/Updater.app"
sign_component no "$SPARKLE_FRAMEWORK"
sign_component no "$APP_RESOURCES/AgentDockShortcutLauncher"
sign_component no "$APP_BUNDLE"

/usr/bin/codesign --verify --strict "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
/usr/bin/codesign --verify --strict "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
/usr/bin/codesign --verify --strict "$SPARKLE_VERSION_DIR/Updater.app"
/usr/bin/codesign --verify --strict "$SPARKLE_FRAMEWORK"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
