#!/usr/bin/env bash
# Runs every spec in certora/specs against the appropriate target.
# PATH A (harness) for money properties, PATH B (production source) for parametric ones.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CERTORAKEY:?export CERTORAKEY=... first (Certora Prover key)}"

echo "== PATH A: accounting =="
certoraRun certora/conf/accounting.conf  "$@" || true

echo "== PATH A: withdrawals =="
certoraRun certora/conf/withdrawal.conf  "$@" || true

echo "== PATH A: wind-down =="
certoraRun certora/conf/winddown.conf    "$@" || true

echo "== PATH A: transitions =="
certoraRun certora/conf/transitions.conf "$@" || true

echo "== PATH B: parametric on production source =="
certoraRun certora/conf/params.conf      "$@" || true
