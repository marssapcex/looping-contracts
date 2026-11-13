#!/usr/bin/env bash
# Runs every spec. Gọi từ đâu cũng được: bash verification/scripts/run-certora.sh
# Lọc 1 spec: bash verification/scripts/run-certora.sh ghost
set -uo pipefail
cd "$(dirname "$0")/.."

: "${CERTORAKEY:?chưa có CERTORAKEY — export CERTORAKEY=... trước}"
command -v certoraRun >/dev/null || { echo "!! chưa cài certora-cli"; exit 1; }

ALL="ghost accounting withdrawal winddown transitions params"
SET="${*:-$ALL}"

fail=0
for n in $SET; do
  conf="certora/conf/$n.conf"
  [ -f "$conf" ] || { echo "!! không thấy $conf (tên đúng: $ALL)"; fail=1; continue; }
  echo "==> $conf"
  certoraRun "$conf" || fail=1
done
exit $fail
