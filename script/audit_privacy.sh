#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "error: gitleaks is required (install with: brew install gitleaks)" >&2
  exit 1
fi

echo "Scanning the complete Git history for secrets (values are always redacted)..."
gitleaks git "$ROOT_DIR" \
  --log-opts='--all --full-history' \
  --redact=100 \
  --no-banner \
  --log-level error

echo "Scanning uncommitted tracked changes for secrets..."
gitleaks git "$ROOT_DIR" \
  --pre-commit \
  --redact=100 \
  --no-banner \
  --log-level error

python3 "$ROOT_DIR/script/audit_publication_metadata.py" --all-history

echo "Scanning tracked files for machine-specific home paths..."
HOME_PATH_MATCHES="$(
  git -C "$ROOT_DIR" grep -nE \
    '/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|[A-Za-z]:\\Users\\[^\\]+' \
    -- . \
    | /usr/bin/grep -Fv '/Users/person/Secret/Path/SensitiveRepository' \
    || true
)"
if [[ -n "$HOME_PATH_MATCHES" ]]; then
  printf '%s\n' "$HOME_PATH_MATCHES" >&2
  echo "error: tracked files contain a machine-specific home path" >&2
  exit 1
fi

echo "Scanning tracked filenames for private data and credential formats..."
SENSITIVE_TRACKED_FILES="$(
  git -C "$ROOT_DIR" ls-files \
    | /usr/bin/grep -Ei \
      '(^|/)(\.env($|\.)|.*\.(cer|crt|der|key|mobileprovision|p8|p12|pem|pfx|sqlite|db|log)$|id_(rsa|ed25519)|credentials?|secrets?)(/|$)' \
    || true
)"
if [[ -n "$SENSITIVE_TRACKED_FILES" ]]; then
  printf '%s\n' "$SENSITIVE_TRACKED_FILES" >&2
  echo "error: sensitive-looking files are tracked" >&2
  exit 1
fi

"$ROOT_DIR/script/validate_site.sh"

echo "Privacy audit passed."
