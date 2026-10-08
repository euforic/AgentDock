#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <appcast.xml>" >&2
  exit 64
fi

appcast_path="$1"
if [[ ! -f "$appcast_path" ]]; then
  echo "Appcast is not a regular file: $appcast_path" >&2
  exit 66
fi

xmllint_path="$(command -v xmllint || true)"
if [[ -z "$xmllint_path" ]]; then
  echo "xmllint is required to inspect the public appcast." >&2
  exit 69
fi

version="$(
  "$xmllint_path" --nonet --xpath \
    'string((//*[local-name()="item"]/*[local-name()="shortVersionString"] | //*[local-name()="item"]/@*[local-name()="shortVersionString"])[1])' \
    "$appcast_path"
)"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Public appcast does not contain a valid semantic short version." >&2
  exit 65
fi

printf '%s\n' "$version"
