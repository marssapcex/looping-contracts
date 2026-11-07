#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
../.audit-tools/bin/forge test -vv > evidence/supplied-tests.log 2>&1
(
  cd upstream-check
  ../../.audit-tools/bin/forge test -vv
) > evidence/deployed-source-tests.log 2>&1
node scripts/verify-artifacts.mjs
./scripts/check-supplied.sh
./scripts/test-transient.sh
python3 scripts/validate_evidence.py
tail -n 5 evidence/supplied-tests.log
tail -n 5 evidence/deployed-source-tests.log
