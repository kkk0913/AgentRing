#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin"
cat > "$WORK/bin/gh" <<'MOCK'
#!/bin/bash
if [[ "$HISTORY_CASE" == error ]]; then exit 1; fi
if [[ "$*" == *releases/latest* ]]; then
  if [[ "$HISTORY_CASE" == latest_error ]]; then exit 1; fi
  printf '{"tag_name":"v0.1.12","assets":[]}\n'
elif [[ "$HISTORY_CASE" == first ]]; then printf '[[]]\n'
elif [[ "$HISTORY_CASE" == draft ]]; then printf '[[{"draft":true,"prerelease":false}]]\n'
else printf '[[{"draft":false,"prerelease":false}]]\n'; fi
MOCK
chmod +x "$WORK/bin/gh"
export PATH="$WORK/bin:$PATH"
for HISTORY_CASE in first draft stable; do
 export HISTORY_CASE
 bash "$ROOT/Scripts/read-release-history.sh" test/repo "$WORK/result.json"
 if [[ "$HISTORY_CASE" == stable ]]; then jq -e '.tag_name == "v0.1.12"' "$WORK/result.json" >/dev/null
 else jq -e '. == {}' "$WORK/result.json" >/dev/null; fi
 echo "PASS: release history $HISTORY_CASE"
done
for HISTORY_CASE in error latest_error; do
 export HISTORY_CASE
 if bash "$ROOT/Scripts/read-release-history.sh" test/repo "$WORK/result.json"; then echo "FAIL: API error accepted"; exit 1; fi
 echo "PASS: rejects $HISTORY_CASE"
done
