#!/usr/bin/env bash
# Empirical pre-check: real bytecode, scripted adversarial sequences.
# Gọi từ đâu cũng được: bash verification/scripts/run-audit.sh
set -uo pipefail
cd "$(dirname "$0")/.."

node scripts/compile.js || exit 1
node scripts/audit.js  | grep -E '^FAIL|=== '
node scripts/audit2.js | grep -E '^FAIL|=== '
# audit3 = probe thăm dò, in ra số liệu chứ không PASS/FAIL
node scripts/audit3.js | tail -5
echo "==> nếu 2 dòng trên đều 0 FAIL là môi trường OK"
