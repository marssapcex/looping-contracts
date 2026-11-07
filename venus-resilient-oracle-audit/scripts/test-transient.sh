#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
../.audit-tools/bin/anvil --host 127.0.0.1 --port 8546 --chain-id 31337 --hardfork cancun --silent > ../.audit-tools/venus-anvil-test.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true' EXIT
sleep 1
node scripts/upstream-transient-evm.mjs
node scripts/transient-evm.mjs
