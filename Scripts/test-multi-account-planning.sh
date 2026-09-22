#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -t multi-account-planning)"
trap 'rm -f "$TMP"' EXIT

# 纯逻辑与检查拼成单文件执行（swift 脚本模式只接受一个输入文件）
cat "$REPO_ROOT/AgentRing/Models/MultiAccountPlanning.swift" \
    "$REPO_ROOT/Tests/MultiAccountPlanningChecks.swift" > "$TMP"
swift "$TMP"
