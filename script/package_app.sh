#!/usr/bin/env bash
set -euo pipefail

APP_NAME="AgentDock"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
HELPER_BINARY="$APP_BUNDLE/Contents/Resources/AgentDockShortcutLauncher"
SPARKLE_FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
ICON_FILE="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
LICENSE_FILE="$APP_BUNDLE/Contents/Resources/LICENSE.txt"
NOTICES_FILE="$APP_BUNDLE/Contents/Resources/THIRD_PARTY_NOTICES.md"
LICENSES_DIR="$APP_BUNDLE/Contents/Resources/Licenses"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || true)"
if [[ -z "$VERSION" ]]; then
  echo "error: missing CFBundleShortVersionString in $INFO_PLIST" >&2
  exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-alpha\.[0-9]+)?$ ]]; then
  echo "error: CFBundleShortVersionString must use MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-alpha.NUMBER format" >&2
  exit 1
fi
RELEASE_NAME="$APP_NAME-$VERSION"
STAGING_DIR="$DIST_DIR/$RELEASE_NAME"
DMG_STAGING_DIR="$DIST_DIR/.dmg-staging-$RELEASE_NAME"
ZIP_PATH="$DIST_DIR/$RELEASE_NAME.zip"
DMG_PATH="$DIST_DIR/$RELEASE_NAME.dmg"
NOTARY_KEY_PATH="${AGENTDOCK_NOTARY_KEY_PATH:-${CODEXER_NOTARY_KEY_PATH:-}}"
NOTARY_KEY_ID="${AGENTDOCK_NOTARY_KEY_ID:-${CODEXER_NOTARY_KEY_ID:-}}"
NOTARY_ISSUER_ID="${AGENTDOCK_NOTARY_ISSUER_ID:-${CODEXER_NOTARY_ISSUER_ID:-}}"
SIGNING_IDENTITY="${AGENTDOCK_SIGNING_IDENTITY:-${CODEXER_SIGNING_IDENTITY:-}}"
SIGNING_KEYCHAIN="${AGENTDOCK_SIGNING_KEYCHAIN:-${CODEXER_SIGNING_KEYCHAIN:-}}"

fail() {
  echo "error: $*" >&2
  exit 1
}

require_file() {
  [[ -f "$1" ]] || fail "missing required file: $1"
}

require_dir() {
  [[ -d "$1" ]] || fail "missing required directory: $1"
}

require_dir "$APP_BUNDLE"
require_file "$INFO_PLIST"
require_file "$APP_BINARY"
require_file "$HELPER_BINARY"
require_dir "$SPARKLE_FRAMEWORK"
require_file "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
require_file "$SPARKLE_FRAMEWORK/Versions/B/Updater.app/Contents/MacOS/Updater"
require_file "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
require_file "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
require_file "$ICON_FILE"
if ! /usr/bin/cmp -s "$ROOT_DIR/Assets/AppIcon.icns" "$ICON_FILE"; then
  fail "bundled AppIcon.icns does not match the tracked app icon"
fi
require_file "$LICENSE_FILE"
require_file "$NOTICES_FILE"
require_dir "$LICENSES_DIR"
require_file "$LICENSES_DIR/Sparkle-MIT.txt"

NOTARY_VALUES_SET=0
[[ -n "$NOTARY_KEY_PATH" ]] && NOTARY_VALUES_SET=$((NOTARY_VALUES_SET + 1))
[[ -n "$NOTARY_KEY_ID" ]] && NOTARY_VALUES_SET=$((NOTARY_VALUES_SET + 1))
[[ -n "$NOTARY_ISSUER_ID" ]] && NOTARY_VALUES_SET=$((NOTARY_VALUES_SET + 1))
if [[ "$NOTARY_VALUES_SET" -ne 0 && "$NOTARY_VALUES_SET" -ne 3 ]]; then
  fail "set AGENTDOCK_NOTARY_KEY_PATH, AGENTDOCK_NOTARY_KEY_ID, and AGENTDOCK_NOTARY_ISSUER_ID together"
fi
if [[ "$NOTARY_VALUES_SET" -eq 3 ]]; then
  require_file "$NOTARY_KEY_PATH"
  [[ -n "$SIGNING_IDENTITY" ]] || fail "set AGENTDOCK_SIGNING_IDENTITY when notarizing"
fi

PLIST_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
PLIST_ICON="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$INFO_PLIST")"
PLIST_MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")"
PLIST_FEED_URL="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")"
PLIST_PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")"
PLIST_UPDATE_CHECK_INTERVAL="$(/usr/libexec/PlistBuddy -c 'Print :SUScheduledCheckInterval' "$INFO_PLIST")"
PLIST_AUTOMATICALLY_UPDATE="$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$INFO_PLIST")"
PLIST_REQUIRE_SIGNED_FEED="$(/usr/libexec/PlistBuddy -c 'Print :SURequireSignedFeed' "$INFO_PLIST")"
PLIST_VERIFY_BEFORE_EXTRACTION="$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO_PLIST")"
PLIST_POSTHOG_TOKEN="$(/usr/libexec/PlistBuddy -c 'Print :AgentDockPostHogProjectToken' "$INFO_PLIST")"
PLIST_POSTHOG_HOST="$(/usr/libexec/PlistBuddy -c 'Print :AgentDockPostHogHost' "$INFO_PLIST")"

[[ "$PLIST_BUNDLE_ID" == "dev.euforic.agentdock" ]] || fail "unexpected bundle id: $PLIST_BUNDLE_ID"
[[ "$PLIST_ICON" == "AppIcon" ]] || fail "unexpected icon file: $PLIST_ICON"
[[ "$PLIST_MIN_OS" == "26.0" ]] || fail "unexpected minimum macOS version: $PLIST_MIN_OS"
[[ "$PLIST_FEED_URL" == "https://gh.euforic.one/AgentDock/appcast.xml" ]] \
  || fail "unexpected Sparkle feed URL: $PLIST_FEED_URL"
[[ "$PLIST_UPDATE_CHECK_INTERVAL" =~ ^3600([.]0+)?$ ]] \
  || fail "Sparkle update checks must run hourly"
[[ "$PLIST_AUTOMATICALLY_UPDATE" == "false" ]] \
  || fail "Sparkle updates must wait for the update pill by default"
[[ "$PLIST_REQUIRE_SIGNED_FEED" == "true" ]] || fail "signed Sparkle feeds must be required"
[[ "$PLIST_VERIFY_BEFORE_EXTRACTION" == "true" ]] \
  || fail "Sparkle updates must be verified before extraction"
if [[ -n "$PLIST_POSTHOG_TOKEN" || -n "$PLIST_POSTHOG_HOST" ]]; then
  [[ "$PLIST_POSTHOG_TOKEN" =~ ^phc_[A-Za-z0-9_-]{8,128}$ ]] \
    || fail "analytics configuration does not contain a public PostHog project token"
  [[ "$PLIST_POSTHOG_HOST" == "https://us.i.posthog.com" \
    || "$PLIST_POSTHOG_HOST" == "https://eu.i.posthog.com" ]] \
    || fail "analytics configuration does not use an approved regional ingestion host"
fi
if [[ -n "$SIGNING_IDENTITY" && "$SIGNING_IDENTITY" != "-" ]]; then
  [[ -n "$PLIST_PUBLIC_KEY" ]] || fail "production package is missing SUPublicEDKey"
fi

file "$APP_BINARY" | grep -q "Mach-O 64-bit executable arm64" || fail "$APP_BINARY is not an arm64 executable"
file "$HELPER_BINARY" | grep -q "Mach-O 64-bit executable arm64" || fail "$HELPER_BINARY is not an arm64 executable"
file "$SPARKLE_FRAMEWORK/Versions/B/Sparkle" | grep -q "Mach-O universal binary" \
  || fail "Sparkle.framework is not the expected universal framework"

/usr/bin/codesign --verify --strict --verbose=2 \
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
/usr/bin/codesign --verify --strict --verbose=2 \
  "$SPARKLE_FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
/usr/bin/codesign --verify --strict --verbose=2 "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
/usr/bin/codesign --verify --strict --verbose=2 "$SPARKLE_FRAMEWORK"

rm -rf "$STAGING_DIR" "$DMG_STAGING_DIR" "$ZIP_PATH" "$DMG_PATH"
mkdir -p "$STAGING_DIR"

/usr/bin/ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
/usr/bin/xattr -cr "$STAGING_DIR/$APP_NAME.app"

/usr/bin/xattr -cr "$STAGING_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME.app"

create_zip() {
  /bin/rm -f "$ZIP_PATH"
  COPYFILE_DISABLE=1 /usr/bin/ditto -c -k \
    --keepParent \
    --norsrc \
    --noextattr \
    --noqtn \
    --noacl \
    "$STAGING_DIR/$APP_NAME.app" \
    "$ZIP_PATH"
}

notarytool() {
  xcrun notarytool "$@" \
    --key "$NOTARY_KEY_PATH" \
    --key-id "$NOTARY_KEY_ID" \
    --issuer "$NOTARY_ISSUER_ID"
}

create_zip

if [[ "$NOTARY_VALUES_SET" -eq 3 ]]; then
  notarytool submit "$ZIP_PATH" --wait
  xcrun stapler staple "$STAGING_DIR/$APP_NAME.app"
  xcrun stapler validate "$STAGING_DIR/$APP_NAME.app"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME.app"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$STAGING_DIR/$APP_NAME.app"
  create_zip
fi

mkdir -p "$DMG_STAGING_DIR"
/usr/bin/ditto "$STAGING_DIR/$APP_NAME.app" "$DMG_STAGING_DIR/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_STAGING_DIR/Applications"

USE_DISKUTIL_IMAGE=0
if /usr/sbin/diskutil image create from -help >/dev/null 2>&1 \
  && COPYFILE_DISABLE=1 /usr/sbin/diskutil image create from \
    --format UDZO \
    --volumeName "$APP_NAME" \
    "$DMG_STAGING_DIR" \
    "$DMG_PATH"; then
  USE_DISKUTIL_IMAGE=1
else
  COPYFILE_DISABLE=1 /usr/bin/hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING_DIR" \
    -fs HFS+ \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"
fi

DMG_VERIFY_MOUNT_DIR="$(/usr/bin/mktemp -d "$DIST_DIR/.dmg-verify-$RELEASE_NAME.XXXXXX")"
cleanup_dmg_verify_mount() {
  /usr/bin/hdiutil detach "$DMG_VERIFY_MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  /bin/rmdir "$DMG_VERIFY_MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup_dmg_verify_mount EXIT

if [[ "$USE_DISKUTIL_IMAGE" -eq 1 ]]; then
  /usr/sbin/diskutil image attach \
    --readOnly \
    --nobrowse \
    --mountPoint "$DMG_VERIFY_MOUNT_DIR" \
    "$DMG_PATH" >/dev/null
else
  /usr/bin/hdiutil attach "$DMG_PATH" \
    -readonly \
    -nobrowse \
    -noautoopen \
    -mountpoint "$DMG_VERIFY_MOUNT_DIR" >/dev/null
fi

DMG_PATH_LEAK=""
while IFS= read -r -d '' candidate; do
  if /usr/bin/strings -a "$candidate" \
    | /usr/bin/grep -Eq '/Users/|/private/var/|/var/folders/|runner/work'; then
    DMG_PATH_LEAK="${candidate#"$DMG_VERIFY_MOUNT_DIR"/}"
    break
  fi
done < <(/usr/bin/find "$DMG_VERIFY_MOUNT_DIR" -type f -print0)

cleanup_dmg_verify_mount
trap - EXIT
[[ -z "$DMG_PATH_LEAK" ]] \
  || fail "DMG contains a build-machine path in $DMG_PATH_LEAK"

if [[ "$NOTARY_VALUES_SET" -eq 3 ]]; then
  DMG_SIGNING_ARGUMENTS=(
    --force
    --timestamp
    --sign "$SIGNING_IDENTITY"
  )
  if [[ -n "$SIGNING_KEYCHAIN" ]]; then
    DMG_SIGNING_ARGUMENTS+=(--keychain "$SIGNING_KEYCHAIN")
  fi
  /usr/bin/codesign "${DMG_SIGNING_ARGUMENTS[@]}" "$DMG_PATH"
  /usr/bin/codesign --verify --strict --verbose=2 "$DMG_PATH"
  notarytool submit "$DMG_PATH" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"
fi

/usr/bin/hdiutil verify "$DMG_PATH"

/bin/rm -rf "$DMG_STAGING_DIR"

echo "Created:"
echo "  $ZIP_PATH"
echo "  $DMG_PATH"
