#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SITE_DIR="$ROOT_DIR/site"
APP_ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.png"
APP_ICON_ICNS="$ROOT_DIR/Assets/AppIcon.icns"

required_files=(
  index.html
  styles.css
  app.js
  robots.txt
  sitemap.xml
  assets/app-icon.png
)

for relative_path in "${required_files[@]}"; do
  if [[ ! -f "$SITE_DIR/$relative_path" ]]; then
    echo "error: missing site file: $relative_path" >&2
    exit 1
  fi
done

if ! /usr/bin/cmp -s "$APP_ICON_SOURCE" "$SITE_DIR/assets/app-icon.png"; then
  echo "error: website icon does not match Assets/AppIcon.png" >&2
  exit 1
fi

ICON_CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agentdock-icon-check.XXXXXX")"
cleanup() {
  rm -rf "$ICON_CHECK_DIR"
}
trap cleanup EXIT
/usr/bin/iconutil -c iconset "$APP_ICON_ICNS" -o "$ICON_CHECK_DIR/AppIcon.iconset"
if ! /usr/bin/cmp -s "$APP_ICON_SOURCE" "$ICON_CHECK_DIR/AppIcon.iconset/icon_512x512@2x.png"; then
  echo "error: AppIcon.icns does not contain the website icon artwork" >&2
  exit 1
fi

/usr/bin/python3 - "$SITE_DIR/index.html" <<'PY'
from html.parser import HTMLParser
from pathlib import Path
import sys


class SiteParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.ids = []
        self.local_references = []
        self.fragment_references = []
        self.title_count = 0
        self.h1_count = 0

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if "id" in values:
            self.ids.append(values["id"])
        if tag == "title":
            self.title_count += 1
        if tag == "h1":
            self.h1_count += 1
        for name in ("href", "src"):
            reference = values.get(name)
            if not reference:
                continue
            if reference.startswith("#"):
                self.fragment_references.append(reference[1:])
            elif not reference.startswith(("https://", "http://", "mailto:", "data:")):
                self.local_references.append(reference)


source_path = Path(sys.argv[1])
parser = SiteParser()
parser.feed(source_path.read_text(encoding="utf-8"))
if parser.title_count != 1:
    raise SystemExit(f"expected one title element, found {parser.title_count}")
if parser.h1_count != 1:
    raise SystemExit(f"expected one h1 element, found {parser.h1_count}")
if len(parser.ids) != len(set(parser.ids)):
    raise SystemExit("duplicate HTML id")
missing_fragments = sorted(set(parser.fragment_references) - set(parser.ids))
if missing_fragments:
    raise SystemExit(f"missing fragment targets: {missing_fragments}")
missing_files = [reference for reference in parser.local_references
                 if not (source_path.parent / reference).is_file()]
if missing_files:
    raise SystemExit(f"missing local resources: {missing_files}")
PY

NODE_BINARY="${NODE_BINARY:-$(command -v node || true)}"
if [[ -z "$NODE_BINARY" || ! -x "$NODE_BINARY" ]]; then
  echo "error: node is required to validate site/app.js" >&2
  exit 1
fi
"$NODE_BINARY" --check "$SITE_DIR/app.js"
/usr/bin/xmllint --noout "$SITE_DIR/sitemap.xml"

/usr/bin/grep -Fq 'data-download' "$SITE_DIR/index.html"
/usr/bin/grep -Fq 'https://github.com/euforic/AgentDock/releases' "$SITE_DIR/index.html"
# The JavaScript template expression must remain literal.
# shellcheck disable=SC2016
/usr/bin/grep -Fq 'api.github.com/repos/${repository}/releases/latest' "$SITE_DIR/app.js"
/usr/bin/grep -Fq 'prefers-reduced-motion' "$SITE_DIR/styles.css"
/usr/bin/grep -Fq 'Skip to content' "$SITE_DIR/index.html"
/usr/bin/grep -Fq 'name="referrer" content="no-referrer"' "$SITE_DIR/index.html"
/usr/bin/grep -Fq 'Content-Security-Policy' "$SITE_DIR/index.html"

if /usr/bin/grep -R -E '/Users/|/private/var/|SPARKLE_PRIVATE|BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' "$SITE_DIR"; then
  echo "error: site contains a private path or secret marker" >&2
  exit 1
fi

if [[ "${AGENTDOCK_SITE_NETWORK_VALIDATION:-0}" == "1" ]]; then
  latest_release_json="$(/usr/bin/curl -fsSL \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/euforic/AgentDock/releases/latest)"
  dmg_url="$(printf '%s' "$latest_release_json" \
    | /usr/bin/python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(asset["browser_download_url"] for asset in data["assets"] if asset["name"].endswith(".dmg")))')"
  /usr/bin/curl -fsSIL "$dmg_url" >/dev/null
fi

echo "Site validation passed."
