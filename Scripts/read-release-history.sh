#!/bin/bash
# Only a successful, empty stable-release listing counts as a first release.
set -euo pipefail
REPO="${1:?repository required}"
OUTPUT="${2:?output path required}"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
gh api --paginate --slurp "repos/$REPO/releases?per_page=100" > "$WORK/pages.json"
jq -e 'type == "array" and all(.[]; type == "array")' "$WORK/pages.json" >/dev/null
if jq -e '[.[][] | select(.draft == false and .prerelease == false)] | length > 0' "$WORK/pages.json" >/dev/null; then
    gh api "repos/$REPO/releases/latest" > "$WORK/latest.json"
    jq -e '.tag_name | type == "string" and length > 0' "$WORK/latest.json" >/dev/null
else
    printf '{}\n' > "$WORK/latest.json"
fi
cp "$WORK/latest.json" "$OUTPUT"
