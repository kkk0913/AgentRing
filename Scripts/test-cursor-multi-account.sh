#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FILE="$(mktemp -t cursor-multi-account)"
trap 'rm -f "$TEST_FILE"' EXIT
cat "$REPO_ROOT/Tests/Support/CursorAPIStubs.swift" \
    "$REPO_ROOT/AgentRing/Models/CursorUsageData.swift" \
    "$REPO_ROOT/AgentRing/Services/CursorAPIService.swift" \
    "$REPO_ROOT/Tests/CursorMultiAccountChecks.swift" > "$TEST_FILE"
swift "$TEST_FILE"
