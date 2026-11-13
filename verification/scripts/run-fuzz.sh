#!/usr/bin/env bash
# Stateful fuzz: random call sequences + random timestamps, invariants checked after
# EVERY call. Gọi từ đâu cũng được:
#   bash verification/scripts/run-fuzz.sh              # 200 x 60
#   bash verification/scripts/run-fuzz.sh 500 80 42    # runs steps seed
set -uo pipefail
cd "$(dirname "$0")/.."
RUNS="${1:-200}"
STEPS="${2:-60}"
SEED="${3:-900}"
echo "==> fuzz: $RUNS sequences x $STEPS steps, seed $SEED"
node scripts/fuzz.js --runs "$RUNS" --steps "$STEPS" --seed "$SEED"
