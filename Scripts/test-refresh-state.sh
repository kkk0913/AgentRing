#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_FILE="$(mktemp -t refresh-state)"
trap 'rm -f "$TEST_FILE"' EXIT
python3 - "$REPO_ROOT" "$TEST_FILE" <<'PYTHON'
from pathlib import Path
import re, sys
root = Path(sys.argv[1])
source = (root / 'AgentRing/Helpers/DataRefreshManager.swift').read_text()
names = ['fetchCursorUsage', 'fetchAntigravityUsage', 'noteFetchFinished', 'syncPrimaryCursorUsage', 'fetchPlanQuota', 'reconcileCodexUsageState', 'upsertCodexUsage']
methods = []
for name in names:
    match = re.search(r'    private func ' + name + r'\(', source)
    end = source.index('\n    }', match.start()) + len('\n    }')
    methods.append(source[match.start():end].replace('private func', 'func', 1))
harness = (root / 'Tests/RefreshStateChecks.swift').read_text().replace('    // PRODUCTION_METHODS', '\n'.join(methods))
Path(sys.argv[2]).write_text((root / 'AgentRing/Models/MultiAccountPlanning.swift').read_text() + '\n' + (root / 'AgentRing/Models/CodexAccountUsage.swift').read_text() + '\n' + harness)
PYTHON
swift "$TEST_FILE"
