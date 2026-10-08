#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_ICON="$ROOT_DIR/Assets/AppIcon.png"
APP_ICON="$ROOT_DIR/Assets/AppIcon.icns"
SITE_ICON="$ROOT_DIR/site/assets/app-icon.png"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-app-icon.XXXXXX")"
ICONSET_DIR="$TEMP_DIR/AppIcon.iconset"

cleanup() {
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$SOURCE_ICON" ]]; then
  echo "error: missing source icon: $SOURCE_ICON" >&2
  exit 1
fi

WIDTH="$(/usr/bin/sips -g pixelWidth "$SOURCE_ICON" | /usr/bin/awk '/pixelWidth/ { print $2 }')"
HEIGHT="$(/usr/bin/sips -g pixelHeight "$SOURCE_ICON" | /usr/bin/awk '/pixelHeight/ { print $2 }')"
if [[ "$WIDTH" != "1024" || "$HEIGHT" != "1024" ]]; then
  echo "error: source icon must be 1024x1024 pixels" >&2
  exit 1
fi

mkdir -p "$ICONSET_DIR" "$(dirname "$SITE_ICON")"

render_icon() {
  local output_name="$1"
  local pixel_size="$2"
  /usr/bin/sips -z "$pixel_size" "$pixel_size" "$SOURCE_ICON" \
    --out "$ICONSET_DIR/$output_name" >/dev/null
}

render_icon icon_16x16.png 16
render_icon icon_16x16@2x.png 32
render_icon icon_32x32.png 32
render_icon icon_32x32@2x.png 64
render_icon icon_128x128.png 128
render_icon icon_128x128@2x.png 256
render_icon icon_256x256.png 256
render_icon icon_256x256@2x.png 512
render_icon icon_512x512.png 512
cp "$SOURCE_ICON" "$ICONSET_DIR/icon_512x512@2x.png"

/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$TEMP_DIR/AppIcon.icns"
cp "$TEMP_DIR/AppIcon.icns" "$APP_ICON"
cp "$SOURCE_ICON" "$SITE_ICON"

echo "Generated app and website icons from Assets/AppIcon.png."
