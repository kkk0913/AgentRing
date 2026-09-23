#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FILE="$(mktemp -t plan-quota)"
trap 'rm -f "$TEST_FILE"' EXIT
printf 'enum L { static func provider(_ key: String) -> String { key } }\n' > "$TEST_FILE"
cat "$REPO_ROOT/AgentRing/Models/ProviderType.swift" \
    "$REPO_ROOT/AgentRing/Models/PlanQuota.swift" \
    "$REPO_ROOT/AgentRing/Services/PlanQuotaService.swift" \
    "$REPO_ROOT/Tests/PlanQuotaChecks.swift" >> "$TEST_FILE"
swift "$TEST_FILE"
