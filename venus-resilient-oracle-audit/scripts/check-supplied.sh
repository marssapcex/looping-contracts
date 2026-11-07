#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p evidence reference-empty
set +e
(
  cd supplied-check
  ../../.audit-tools/bin/forge build
) > evidence/supplied-compile.log 2>&1
status=$?
set -e
cat evidence/supplied-compile.log
if [ "$status" -eq 0 ]; then
  echo 'ERROR: supplied source unexpectedly compiled' >&2
  exit 1
fi
if ! grep -q 'whenNotPaused' evidence/supplied-compile.log; then
  echo 'ERROR: expected Pausable compile blocker was not observed' >&2
  exit 1
fi
echo 'EXPECTED_FAIL: supplied source does not compile; see evidence/supplied-compile.log'
