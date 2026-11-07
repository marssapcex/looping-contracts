#!/bin/sh
# Exact original calldata, no deal/prank-funded storage or latest-block fallback.
set -eu
: "${BSC_ARCHIVE_RPC:?set BSC_ARCHIVE_RPC to a BSC archive endpoint}"
FORGE=${FORGE:-forge}
"$FORGE" test --match-path poc/FoxLpBondsPoolFork.t.sol --evm-version cancun -vvv
